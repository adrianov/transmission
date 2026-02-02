// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

#include <fmt/format.h>

#include "libtransmission/transmission.h"
#include "libtransmission/announcer.h"
#include "libtransmission/error.h"
#include "libtransmission/log.h"
#include "libtransmission/resume.h"
#include "libtransmission/session.h"
#include "libtransmission/torrent-files.h"
#include "libtransmission/torrent-helpers.h"
#include "libtransmission/torrent-queue.h"
#include "libtransmission/torrent-scripts.h"
#include "libtransmission/torrent.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/verify.h"

bool tr_torrentIsSeedRatioDone(tr_torrent const* tor);

using namespace std::literals;

namespace
{
namespace start_stop_helpers
{
bool torrentShouldQueue(tr_torrent const* const tor)
{
    tr_direction const dir = tor->queue_direction();

    return tor->session->count_queue_free_slots(dir) == 0;
}

bool removeTorrentFile(char const* filename, void* /*user_data*/, tr_error* error)
{
    return tr_sys_path_remove(filename, error);
}

[[nodiscard]] auto build_keep_paths(tr_torrent const* tor)
{
    auto keep_paths = std::unordered_set<std::string>{};
    auto const* const session = tor->session;
    auto const torrents = session->torrents().get_all();

    for (auto const* const other : torrents)
    {
        if (other == tor || !other->has_metainfo())
        {
            continue;
        }

        auto const base = other->current_dir();
        if (std::empty(base))
        {
            continue;
        }

        for (tr_file_index_t i = 0, n = other->file_count(); i < n; ++i)
        {
            if (!other->file_is_wanted(i))
            {
                continue;
            }

            auto const file_path = tr_pathbuf{ base, '/', other->file_subpath(i) };
            keep_paths.emplace(std::string{ file_path.sv() });
            if (session->isIncompleteFileNamingEnabled() && !other->has_file(i))
            {
                keep_paths.emplace(std::string{ tr_pathbuf{ file_path, tr_torrent_files::PartialFileSuffix } });
            }
        }
    }

    return keep_paths;
}

void freeTorrent(tr_torrent* tor)
{
    auto const lock = tor->unique_lock();

    TR_ASSERT(!tor->is_running());

    tr_session* session = tor->session;

    tor->doomed_.emit(tor);

    session->announcer_->removeTorrent(tor);

    session->torrents().remove(tor, tr_time());

    if (!session->isClosing())
    {
        session->torrent_queue().remove(tor->id());
    }

    delete tor;
}
} // namespace start_stop_helpers
} // namespace

void tr_torrent::stop_if_seed_limit_reached()
{
    if (!is_running() || is_stopping_ || !is_done())
    {
        return;
    }

    if (tr_torrentIsSeedRatioDone(this))
    {
        tr_logAddInfoTor(this, _("Seed ratio reached; pausing torrent"));
        stop_soon();
        session->onRatioLimitHit(this);
    }
    else if (auto const secs_left = idle_seconds_left(tr_time()); secs_left && *secs_left <= 0U)
    {
        tr_logAddInfoTor(this, _("Seeding idle limit reached; pausing torrent"));

        stop_soon();
        finished_seeding_by_idle_ = true;
        session->onIdleLimitHit(this);
    }

    if (is_stopping_)
    {
        callScriptIfEnabled(this, TR_SCRIPT_ON_TORRENT_DONE_SEEDING);
    }
}

size_t tr_torrentGetQueuePosition(tr_torrent const* tor)
{
    return tor->queue_position();
}

void tr_torrentSetQueuePosition(tr_torrent* tor, size_t queue_position)
{
    tor->set_queue_position(queue_position);
}

void tr_torrentsQueueMoveTop(tr_torrent* const* torrents_in, size_t torrent_count)
{
    auto torrents = std::vector<tr_torrent*>(torrents_in, torrents_in + torrent_count);
    std::sort(std::rbegin(torrents), std::rend(torrents), tr_torrent::CompareQueuePosition);
    for (auto* const tor : torrents)
    {
        tor->set_queue_position(tr_torrent_queue::MinQueuePosition);
    }
}

void tr_torrentsQueueMoveUp(tr_torrent* const* torrents_in, size_t torrent_count)
{
    auto torrents = std::vector<tr_torrent*>(torrents_in, torrents_in + torrent_count);
    std::sort(std::begin(torrents), std::end(torrents), tr_torrent::CompareQueuePosition);
    for (auto* const tor : torrents)
    {
        if (auto const pos = tor->queue_position(); pos > tr_torrent_queue::MinQueuePosition)
        {
            tor->set_queue_position(pos - 1U);
        }
    }
}

void tr_torrentsQueueMoveDown(tr_torrent* const* torrents_in, size_t torrent_count)
{
    auto torrents = std::vector<tr_torrent*>(torrents_in, torrents_in + torrent_count);
    std::sort(std::rbegin(torrents), std::rend(torrents), tr_torrent::CompareQueuePosition);
    for (auto* const tor : torrents)
    {
        if (auto const pos = tor->queue_position(); pos < tr_torrent_queue::MaxQueuePosition)
        {
            tor->set_queue_position(pos + 1U);
        }
    }
}

void tr_torrentsQueueMoveBottom(tr_torrent* const* torrents_in, size_t torrent_count)
{
    auto torrents = std::vector<tr_torrent*>(torrents_in, torrents_in + torrent_count);
    std::sort(std::begin(torrents), std::end(torrents), tr_torrent::CompareQueuePosition);
    for (auto* const tor : torrents)
    {
        tor->set_queue_position(tr_torrent_queue::MaxQueuePosition);
    }
}

void tr_torrent::start(bool bypass_queue, std::optional<bool> has_any_local_data)
{
    using namespace start_stop_helpers;

    auto const lock = unique_lock();

    switch (activity())
    {
    case TR_STATUS_SEED:
    case TR_STATUS_DOWNLOAD:
        return;

    case TR_STATUS_SEED_WAIT:
    case TR_STATUS_DOWNLOAD_WAIT:
        if (!bypass_queue)
        {
            return;
        }

        break;

    case TR_STATUS_CHECK:
    case TR_STATUS_CHECK_WAIT:
        return;

    case TR_STATUS_STOPPED:
        if (!bypass_queue && torrentShouldQueue(this))
        {
            set_is_queued();
            return;
        }

        break;
    }

    if (set_local_error_if_files_disappeared(this, has_any_local_data))
    {
        return;
    }

    if (tr_torrentIsSeedRatioDone(this))
    {
        tr_logAddInfoTor(this, _("Restarted manually -- disabling its seed ratio"));
        set_seed_ratio_mode(TR_RATIOLIMIT_UNLIMITED);
    }

    is_running_ = true;
    set_dirty();
    session->run_in_session_thread([this]() { start_in_session_thread(); });
}

void tr_torrent::start_in_session_thread()
{
    TR_ASSERT(session->am_in_session_thread());
    auto const lock = unique_lock();

    create_empty_files();

    recheck_completeness();
    set_is_queued(false);

    time_t const now = tr_time();

    is_running_ = true;
    date_started_ = now;
    mark_changed();
    error().clear();
    finished_seeding_by_idle_ = false;

    bytes_uploaded_.start_new_session();
    bytes_downloaded_.start_new_session();
    bytes_corrupt_.start_new_session();
    set_dirty();

    session->announcer_->startTorrent(this);
    lpdAnnounceAt = now;
    started_.emit(this);
}

void tr_torrent::stop_now()
{
    TR_ASSERT(session->am_in_session_thread());
    auto const lock = unique_lock();

    auto const now = tr_time();
    seconds_downloading_before_current_start_ = seconds_downloading(now);
    seconds_seeding_before_current_start_ = seconds_seeding(now);

    is_running_ = false;
    is_stopping_ = false;
    mark_changed();

    if (!session->isClosing())
    {
        tr_logAddInfoTor(this, _("Pausing torrent"));
    }

    session->verify_remove(this);

    stopped_.emit(this);
    session->announcer_->stopTorrent(this);

    session->close_torrent_files(id());

    if (!is_deleting_ && !session->isClosing())
    {
        save_resume_file();
    }

    set_is_queued(false);
}

void tr_torrentRemoveInSessionThread(
    tr_torrent* tor,
    bool delete_flag,
    tr_fileFunc delete_func,
    void* delete_user_data,
    tr_torrent_remove_done_func callback,
    void* callback_user_data)
{
    using namespace start_stop_helpers;

    auto const lock = tor->unique_lock();

    bool ok = true;
    if (delete_flag && tor->has_metainfo())
    {
        tor->session->close_torrent_files(tor->id());
        tor->session->verify_remove(tor);

        if (delete_func == nullptr)
        {
            delete_func = removeTorrentFile;
        }

        auto const delete_func_wrapper = [&delete_func, delete_user_data](char const* filename)
        {
            delete_func(filename, delete_user_data, nullptr);
        };

        auto const keep_paths = build_keep_paths(tor);
        auto keep = tr_torrent_files::KeepFunc{};
        if (!std::empty(keep_paths))
        {
            keep = [&keep_paths](std::string_view filename)
            {
                return keep_paths.find(std::string{ filename }) != std::end(keep_paths);
            };
        }

        tr_error error;
        tor->files().remove(tor->current_dir(), tor->name(), delete_func_wrapper, &error, keep);
        if (error)
        {
            ok = false;
            tor->is_deleting_ = false;

            tor->error().set_local_error(
                fmt::format(
                    fmt::runtime(_("Couldn't remove all torrent files: {error} ({error_code})")),
                    fmt::arg("error", error.message()),
                    fmt::arg("error_code", error.code())));
            tr_torrentStop(tor);
        }
    }

    if (callback != nullptr)
    {
        callback(tor->id(), ok, callback_user_data);
    }

    if (ok)
    {
        tr_torrentFreeInSessionThread(tor);
    }
}

void tr_torrentStop(tr_torrent* tor)
{
    if (!tr_isTorrent(tor))
    {
        return;
    }

    auto const lock = tor->unique_lock();

    tor->start_when_stable_ = false;
    tor->set_dirty();
    tor->session->run_in_session_thread([tor]() { tor->stop_now(); });
}

void tr_torrentRemove(
    tr_torrent* tor,
    bool delete_flag,
    tr_fileFunc delete_func,
    void* delete_user_data,
    tr_torrent_remove_done_func callback,
    void* callback_user_data)
{
    using namespace start_stop_helpers;

    TR_ASSERT(tr_isTorrent(tor));

    tor->is_deleting_ = true;

    tor->session->run_in_session_thread(
        tr_torrentRemoveInSessionThread,
        tor,
        delete_flag,
        delete_func,
        delete_user_data,
        callback,
        callback_user_data);
}

void tr_torrentFreeInSessionThread(tr_torrent* tor)
{
    using namespace start_stop_helpers;

    TR_ASSERT(tr_isTorrent(tor));
    TR_ASSERT(tor->session != nullptr);
    TR_ASSERT(tor->session->am_in_session_thread());

    if (!tor->session->isClosing())
    {
        tr_logAddInfoTor(tor, _("Removing torrent"));
    }

    tor->set_dirty(!tor->is_deleting_);
    tor->stop_now();

    if (tor->is_deleting_)
    {
        tr_torrent_metainfo::remove_file(tor->session->torrentDir(), tor->name(), tor->info_hash_string(), ".torrent"sv);
        tr_torrent_metainfo::remove_file(tor->session->torrentDir(), tor->name(), tor->info_hash_string(), ".magnet"sv);
        tr_torrent_metainfo::remove_file(tor->session->resumeDir(), tor->name(), tor->info_hash_string(), ".resume"sv);
    }

    freeTorrent(tor);
}
