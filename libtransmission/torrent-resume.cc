// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cstddef>
#include <ctime>
#include <string_view>
#include <utility>
#include <vector>

#include "libtransmission/transmission.h"
#include "libtransmission/bitfield.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/torrent.h"

tr_bitfield const& tr_torrent::ResumeHelper::checked_pieces() const noexcept
{
    return tor_.checked_pieces_;
}

void tr_torrent::ResumeHelper::load_checked_pieces(tr_bitfield const& checked, time_t const* mtimes /*file_count()*/)
{
    TR_ASSERT(std::size(checked) == tor_.piece_count());
    tor_.checked_pieces_ = checked;

    auto const n_files = tor_.file_count();
    tor_.file_mtimes_.resize(n_files);

    for (size_t file = 0; file < n_files; ++file)
    {
        auto const found = tor_.find_file(file);
        auto const mtime = found ? found->last_modified_at : 0;

        tor_.file_mtimes_[file] = mtime;

        // if a file has changed, mark its pieces as unchecked
        if (mtime == 0 || mtime != mtimes[file])
        {
            auto const [piece_begin, piece_end] = tor_.piece_span_for_file(file);
            tor_.checked_pieces_.unset_span(piece_begin, piece_end);
        }
    }
}

tr_bitfield const& tr_torrent::ResumeHelper::blocks() const noexcept
{
    return tor_.completion_.blocks();
}

void tr_torrent::ResumeHelper::load_blocks(tr_bitfield blocks)
{
    tor_.completion_.set_blocks(std::move(blocks));
}

time_t tr_torrent::ResumeHelper::date_active() const noexcept
{
    return tor_.date_active_;
}

time_t tr_torrent::ResumeHelper::date_added() const noexcept
{
    return tor_.date_added_;
}

void tr_torrent::ResumeHelper::load_date_added(time_t when) noexcept
{
    tor_.date_added_ = when;
}

time_t tr_torrent::ResumeHelper::date_done() const noexcept
{
    return tor_.date_done_;
}

void tr_torrent::ResumeHelper::load_date_done(time_t when) noexcept
{
    tor_.date_done_ = when;
}

time_t tr_torrent::ResumeHelper::date_last_played() const noexcept
{
    return tor_.date_last_played_;
}

void tr_torrent::ResumeHelper::load_date_last_played(time_t when) noexcept
{
    tor_.date_last_played_ = when;
}

time_t tr_torrent::ResumeHelper::seconds_downloading(time_t now) const noexcept
{
    return tor_.seconds_downloading(now);
}

void tr_torrent::ResumeHelper::load_seconds_downloading_before_current_start(time_t when) noexcept
{
    tor_.seconds_downloading_before_current_start_ = when;
}

time_t tr_torrent::ResumeHelper::seconds_seeding(time_t now) const noexcept
{
    return tor_.seconds_seeding(now);
}

void tr_torrent::ResumeHelper::load_seconds_seeding_before_current_start(time_t when) noexcept
{
    tor_.seconds_seeding_before_current_start_ = when;
}

void tr_torrent::ResumeHelper::load_download_dir(std::string_view const dir) noexcept
{
    bool const is_current_dir = tor_.current_dir_ == tor_.download_dir_;
    tor_.download_dir_ = dir;
    if (is_current_dir)
    {
        tor_.current_dir_ = tor_.download_dir_;
    }
}

void tr_torrent::ResumeHelper::load_incomplete_dir(std::string_view const dir) noexcept
{
    bool const is_current_dir = tor_.current_dir_ == tor_.incomplete_dir_;
    tor_.incomplete_dir_ = dir;
    if (is_current_dir)
    {
        tor_.current_dir_ = tor_.incomplete_dir_;
    }
}

void tr_torrent::ResumeHelper::load_start_when_stable(bool const val) noexcept
{
    tor_.start_when_stable_ = val;
}

bool tr_torrent::ResumeHelper::start_when_stable() const noexcept
{
    return tor_.start_when_stable_;
}

std::vector<time_t> const& tr_torrent::ResumeHelper::file_mtimes() const noexcept
{
    return tor_.file_mtimes_;
}
