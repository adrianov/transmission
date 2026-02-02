// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <optional>
#include <string>

#include <fmt/format.h>

#include "libtransmission/transmission.h"
#include "libtransmission/error.h"
#include "libtransmission/log.h"
#include "libtransmission/platform.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrent-files.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/utils.h"

void tr_torrent::set_verify_state(VerifyState const state)
{
    TR_ASSERT(state == VerifyState::None || state == VerifyState::Queued || state == VerifyState::Active);

    verify_state_ = state;
    verify_progress_ = {};
    mark_changed();
}

tr_torrent_metainfo const& tr_torrent::VerifyMediator::metainfo() const
{
    return tor_->metainfo_;
}

std::optional<std::string> tr_torrent::VerifyMediator::find_file(tr_file_index_t const file_index) const
{
    if (auto const found = tor_->find_file(file_index); found)
    {
        return std::string{ found->filename().sv() };
    }

    return {};
}

void tr_torrent::update_file_path(tr_file_index_t file, std::optional<bool> has_file) const
{
    auto const found = find_file(file);
    if (!found)
    {
        return;
    }

    auto const has = has_file ? *has_file : this->has_file(file);
    auto const needs_suffix = session->isIncompleteFileNamingEnabled() && !has;
    auto const oldpath = found->filename();
    auto const newpath = needs_suffix ?
        tr_pathbuf{ found->base(), '/', file_subpath(file), tr_torrent_files::PartialFileSuffix } :
        tr_pathbuf{ found->base(), '/', file_subpath(file) };

    if (tr_sys_path_is_same(oldpath, newpath))
    {
        return;
    }

    if (auto error = tr_error{}; !tr_sys_path_rename(oldpath, newpath, &error))
    {
        tr_logAddErrorTor(
            this,
            fmt::format(
                fmt::runtime(_("Couldn't move '{old_path}' to '{path}': {error} ({error_code})")),
                fmt::arg("old_path", oldpath),
                fmt::arg("path", newpath),
                fmt::arg("error", error.message()),
                fmt::arg("error_code", error.code())));
    }
}

void tr_torrent::VerifyMediator::on_verify_queued()
{
    tr_logAddTraceTor(tor_, "Queued for verification");
    tor_->set_verify_state(VerifyState::Queued);
}

void tr_torrent::VerifyMediator::on_verify_started()
{
    tr_logAddDebugTor(tor_, "Verifying torrent");
    time_started_ = tr_time();
    tor_->set_verify_state(VerifyState::Active);
}

void tr_torrent::VerifyMediator::on_piece_checked(tr_piece_index_t const piece, bool const has_piece)
{
    if (auto const had_piece = tor_->has_piece(piece); !has_piece || !had_piece)
    {
        tor_->set_has_piece(piece, has_piece);
        tor_->set_dirty();
    }

    tor_->checked_pieces_.set(piece, true);
    tor_->mark_changed();
    tor_->verify_progress_ = std::clamp(static_cast<float>(piece + 1U) / tor_->metainfo_.piece_count(), 0.0F, 1.0F);
}

// (usually called from tr_verify_worker's thread)
void tr_torrent::VerifyMediator::on_verify_done(bool const aborted)
{
    if (time_started_.has_value())
    {
        auto const total_size = tor_->total_size();
        auto const duration_secs = tr_time() - *time_started_;
        tr_logAddDebugTor(
            tor_,
            fmt::format(
                "Verification is done. It took {} seconds to verify {} bytes ({} bytes per second)",
                duration_secs,
                total_size,
                total_size / (1 + duration_secs)));
    }

    tor_->set_verify_state(VerifyState::None);

    if (!aborted && !tor_->is_deleting_)
    {
        tor_->session->run_in_session_thread(
            // Do not capture the torrent pointer directly, or else we will crash if program
            // execution reaches this point while the session thread is about to free this torrent.
            [tor_id = tor_->id(), session = tor_->session]()
            {
                auto* const tor = session->torrents().get(tor_id);
                if (tor == nullptr || tor->is_deleting_)
                {
                    return;
                }

                for (tr_file_index_t file = 0, n_files = tor->file_count(); file < n_files; ++file)
                {
                    tor->update_file_path(file, {});
                }

                tor->recheck_completeness();

                if (tor->verify_done_callback_)
                {
                    tor->verify_done_callback_(tor);
                }

                if (tor->start_when_stable_)
                {
                    tor->start(false, !tor->checked_pieces_.has_none());
                }
            });
    }
}
