// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno> // EINVAL
#include <chrono>
#include <cstddef> // size_t
#include <ctime>
#include <map>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

#include <fmt/chrono.h>
#include <fmt/format.h>

#include <small/map.hpp>

#include "libtransmission/transmission.h"
#include "libtransmission/tr-macros.h"

#include "libtransmission/announcer.h"
#include "libtransmission/bandwidth.h"
#include "libtransmission/completion.h"
#include "libtransmission/crypto-utils.h" // for tr_sha1()
#include "libtransmission/error.h"
#include "libtransmission/file.h"
#include "libtransmission/inout.h" // tr_ioTestPiece()
#include "libtransmission/log.h"
#include "libtransmission/magnet-metainfo.h"
#include "libtransmission/peer-common.h"
#include "libtransmission/peer-mgr.h"
#include "libtransmission/resume.h"
#include "libtransmission/session.h"
#include "libtransmission/subprocess.h"
#include "libtransmission/torrent-ctor.h"
#include "libtransmission/torrent-magnet.h"
#include "libtransmission/torrent-metainfo.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrent-helpers.h"
#include "libtransmission/torrent-scripts.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/utils.h"
#include "libtransmission/version.h"
#include "libtransmission/web-utils.h"

struct tr_ctor;

bool tr_torrentGetSeedRatioBytes(tr_torrent const* tor, uint64_t* setme_left, uint64_t* setme_goal);
bool tr_torrentIsSeedRatioDone(tr_torrent const* tor);

using namespace std::literals;
using namespace libtransmission::Values;

// ---

char const* tr_torrentName(tr_torrent const* tor)
{
    return tor != nullptr ? tor->name().c_str() : "";
}

tr_torrent_id_t tr_torrentId(tr_torrent const* tor)
{
    return tor != nullptr ? tor->id() : -1;
}

tr_torrent* tr_torrentFindFromId(tr_session* session, tr_torrent_id_t id)
{
    return session->torrents().get(id);
}

tr_torrent* tr_torrentFindFromMetainfo(tr_session* session, tr_torrent_metainfo const* metainfo)
{
    if (session == nullptr || metainfo == nullptr)
    {
        return nullptr;
    }

    return session->torrents().get(metainfo->info_hash());
}

tr_torrent* tr_torrentFindFromMagnetLink(tr_session* session, char const* magnet_link)
{
    return magnet_link == nullptr ? nullptr : session->torrents().get(magnet_link);
}

bool tr_torrentSetMetainfoFromFile(tr_torrent* tor, tr_torrent_metainfo const* metainfo, char const* filename)
{
    if (tr_torrentHasMetadata(tor))
    {
        return false;
    }

    auto error = tr_error{};
    tor->use_metainfo_from_file(metainfo, filename, &error);
    if (error)
    {
        tor->error().set_local_error(
            fmt::format(
                fmt::runtime(_("Couldn't use metainfo from '{path}' for '{magnet}': {error} ({error_code})")),
                fmt::arg("path", filename),
                fmt::arg("magnet", tor->magnet()),
                fmt::arg("error", error.message()),
                fmt::arg("error_code", error.code())));
        return false;
    }

    return true;
}

// ---

bool did_files_disappear(tr_torrent* tor, std::optional<bool> has_any_local_data)
{
    auto const has = has_any_local_data ? *has_any_local_data : tor->has_any_local_data();
    return tor->has_total() > 0 && !has;
}

bool set_local_error_if_files_disappeared(tr_torrent* tor, std::optional<bool> has_any_local_data)
{
    auto const files_disappeared = did_files_disappear(tor, has_any_local_data);

    if (files_disappeared)
    {
        tr_logAddTraceTor(tor, "[LAZY] uh oh, the files disappeared");
        tor->error().set_local_error(
            _("No data found! Ensure your drives are connected or use \"Set Location\". "
              "To re-download, use \"Verify Local Data\" and start the torrent afterwards."));
    }

    return files_disappeared;
}

// --- PER-TORRENT UL / DL SPEEDS

void tr_torrentSetSpeedLimit_KBps(tr_torrent* const tor, tr_direction const dir, size_t const limit_kbyps)
{
    tor->set_speed_limit(dir, Speed{ limit_kbyps, Speed::Units::KByps });
}

size_t tr_torrentGetSpeedLimit_KBps(tr_torrent const* const tor, tr_direction const dir)
{
    TR_ASSERT(tr_isTorrent(tor));
    TR_ASSERT(tr_isDirection(dir));

    return tor->speed_limit(dir).count(Speed::Units::KByps);
}

void tr_torrentUseSpeedLimit(tr_torrent* const tor, tr_direction const dir, bool const enabled)
{
    TR_ASSERT(tr_isTorrent(tor));
    TR_ASSERT(tr_isDirection(dir));

    tor->use_speed_limit(dir, enabled);
}

bool tr_torrentUsesSpeedLimit(tr_torrent const* const tor, tr_direction const dir)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->uses_speed_limit(dir);
}

void tr_torrentUseSessionLimits(tr_torrent* const tor, bool const enabled)
{
    TR_ASSERT(tr_isTorrent(tor));

    if (tor->bandwidth().honor_parent_limits(TR_UP, enabled) || tor->bandwidth().honor_parent_limits(TR_DOWN, enabled))
    {
        tor->set_dirty();
    }
}

bool tr_torrentUsesSessionLimits(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->uses_session_limits();
}

// --- Download Ratio

void tr_torrentSetRatioMode(tr_torrent* const tor, tr_ratiolimit mode)
{
    TR_ASSERT(tr_isTorrent(tor));

    tor->set_seed_ratio_mode(mode);
}

tr_ratiolimit tr_torrentGetRatioMode(tr_torrent const* const tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->seed_ratio_mode();
}

void tr_torrentSetRatioLimit(tr_torrent* const tor, double desired_ratio)
{
    TR_ASSERT(tr_isTorrent(tor));

    tor->set_seed_ratio(desired_ratio);
}

double tr_torrentGetRatioLimit(tr_torrent const* const tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->seed_ratio();
}

// ---

void tr_torrentSetIdleMode(tr_torrent* const tor, tr_idlelimit mode)
{
    TR_ASSERT(tr_isTorrent(tor));

    tor->set_idle_limit_mode(mode);
}

tr_idlelimit tr_torrentGetIdleMode(tr_torrent const* const tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->idle_limit_mode();
}

void tr_torrentSetIdleLimit(tr_torrent* const tor, uint16_t idle_minutes)
{
    TR_ASSERT(tr_isTorrent(tor));

    tor->set_idle_limit_minutes(idle_minutes);
}

uint16_t tr_torrentGetIdleLimit(tr_torrent const* const tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->idle_limit_minutes();
}

// ---

// Sniff out newly-added seeds so that they can skip the verify step
bool tr_torrent::is_new_torrent_a_seed()
{
    if (!has_metainfo())
    {
        return false;
    }

    for (tr_file_index_t i = 0, n = file_count(); i < n; ++i)
    {
        // it's not a new seed if a file is missing
        auto const found = find_file(i);
        if (!found)
        {
            return false;
        }

        // it's not a new seed if a file is partial
        if (tr_strv_ends_with(found->filename(), tr_torrent_files::PartialFileSuffix))
        {
            return false;
        }

        // it's not a new seed if a file size is wrong
        if (found->size != file_size(i))
        {
            return false;
        }

        // it's not a new seed if it was modified after it was added
        if (found->last_modified_at >= date_added_)
        {
            return false;
        }
    }

    // check the first piece
    return ensure_piece_is_checked(0);
}

void tr_torrent::on_metainfo_updated()
{
    completion_ = tr_completion{ this, &block_info() };
    obfuscated_hash_ = tr_sha1::digest("req2"sv, info_hash());
    fpm_ = tr_file_piece_map{ metainfo_ };
    file_mtimes_.resize(file_count());
    file_priorities_ = tr_file_priorities{ &fpm_ };
    files_wanted_ = tr_files_wanted{ &fpm_ };
    checked_pieces_ = tr_bitfield{ size_t(piece_count()) };
    update_piece_priority_state();
}

void tr_torrent::on_metainfo_completed()
{
    // we can look for files now that we know what files are in the torrent
    refresh_current_dir();

    callScriptIfEnabled(this, TR_SCRIPT_ON_TORRENT_ADDED);

    if (session->shouldFullyVerifyAddedTorrents() || !is_new_torrent_a_seed())
    {
        // Potentially, we are in `tr_torrent::init`,
        // and we don't want any file created before `tr_torrent::start`
        // so we Verify but we don't Create files.
        tr_torrentVerify(this);
    }
    else
    {
        completion_.set_has_all();
        recheck_completeness();
        date_done_ = date_added_; // Must be after recheck_completeness()

        if (start_when_stable_)
        {
            start(false, {});
        }
        else if (is_running())
        {
            stop_soon();
        }
    }
}

void tr_torrent::init(tr_ctor const& ctor)
{
    session = ctor.session();
    TR_ASSERT(session != nullptr);
    auto const lock = unique_lock();

    auto const now_sec = tr_time();

    on_metainfo_updated();

    if (auto dir = ctor.download_dir(TR_FORCE); !std::empty(dir))
    {
        download_dir_ = dir;
    }
    else if (dir = ctor.download_dir(TR_FALLBACK); !std::empty(dir))
    {
        download_dir_ = dir;
    }

    if (tr_sessionIsIncompleteDirEnabled(session))
    {
        auto const& dir = ctor.incomplete_dir();
        incomplete_dir_ = !std::empty(dir) ? dir : session->incompleteDir();
    }

    bandwidth().set_parent(&session->top_bandwidth_);
    bandwidth().set_priority(ctor.bandwidth_priority());
    error().clear();
    finished_seeding_by_idle_ = false;

    set_labels(ctor.labels());

    session->addTorrent(this);

    TR_ASSERT(bytes_downloaded_.during_this_session() == 0U);
    TR_ASSERT(bytes_uploaded_.during_this_session() == 0);

    mark_changed();

    // these are defaults that will be overwritten by the resume file
    date_added_ = now_sec;
    set_sequential_download(session->sequential_download());
    set_sequential_download_mode(session->sequential_download_mode());

    tr_resume::fields_t loaded = {};

    {
        // tr_resume::load() calls a lot of tr_torrentSetFoo() methods
        // that set things as dirty, but... these settings being loaded are
        // the same ones that would be saved back again, so don't let them
        // affect the 'is dirty' flag.
        auto const was_dirty = is_dirty();
        auto resume_helper = ResumeHelper{ *this };
        loaded = tr_resume::load(this, resume_helper, tr_resume::All, ctor);
        set_dirty(was_dirty);
        tr_torrent_metainfo::migrate_file(session->torrentDir(), name(), info_hash_string(), ".torrent"sv);
    }

    completeness_ = completion_.status();

    ctor.init_torrent_priorities(*this);
    ctor.init_torrent_wanted(*this);

    // Always recalculate file order for alphabetical download ordering
    recalculate_file_order();

    refresh_current_dir();

    if ((loaded & tr_resume::Speedlimit) == 0)
    {
        use_speed_limit(TR_UP, false);
        set_speed_limit(TR_UP, session->speed_limit(TR_UP));
        use_speed_limit(TR_DOWN, false);
        set_speed_limit(TR_DOWN, session->speed_limit(TR_DOWN));
        tr_torrentUseSessionLimits(this, true);
    }

    if ((loaded & tr_resume::Ratiolimit) == 0)
    {
        set_seed_ratio_mode(TR_RATIOLIMIT_GLOBAL);
        set_seed_ratio(session->desiredRatio());
    }

    if ((loaded & tr_resume::Idlelimit) == 0)
    {
        set_idle_limit_mode(TR_IDLELIMIT_GLOBAL);
        set_idle_limit_minutes(session->idleLimitMinutes());
    }

    auto has_any_local_data = std::optional<bool>{};
    // only scan the filesystem for existing data when no resume-file progress was loaded
    // (if resume progress is already known, skip the on-startup scan entirely)
    // only scan the filesystem for existing data when the resume file
    // didn't record any progress OR it recorded zero verified blocks
    if (((loaded & tr_resume::Progress) == 0) || this->has_none())
    {
        has_any_local_data = std::any_of(
            std::begin(file_mtimes_),
            std::end(file_mtimes_),
            [](auto mtime) { return mtime > 0; });
    }

    auto const file_path = store_file();

    // if we don't have a local .torrent or .magnet file already,
    // assume the torrent is new
    bool const is_new_torrent = !tr_sys_path_exists(file_path);

    if (is_new_torrent)
    {
        auto error = tr_error{};

        if (has_metainfo()) // torrent file
        {
            ctor.save(file_path, &error);
        }
        else // magnet link
        {
            auto const magnet_link = magnet();
            tr_file_save(file_path, magnet_link, &error);
        }

        if (error)
        {
            this->error().set_local_error(
                fmt::format(
                    fmt::runtime(_("Couldn't save '{path}': {error} ({error_code})")),
                    fmt::arg("path", file_path),
                    fmt::arg("error", error.message()),
                    fmt::arg("error_code", error.code())));
        }
    }

    torrent_announcer = session->announcer_->addTorrent(this, &tr_torrent::on_tracker_response);

    if (auto const has_metainfo = this->has_metainfo(); is_new_torrent && has_metainfo)
    {
        on_metainfo_completed();
    }
    else if (start_when_stable_)
    {
        auto const bypass_queue = !has_metainfo; // to fetch metainfo from peers
        start(bypass_queue, has_any_local_data);
    }
    else
    {
        set_local_error_if_files_disappeared(this, has_any_local_data);

        // Auto-verify incomplete torrents on startup if they have existing data
        // This helps recover from cases where files were downloaded but resume state is incorrect
        if (!is_new_torrent && this->has_metainfo() && !is_done() && has_any_local_data && *has_any_local_data && !is_running())
        {
            tr_torrentVerify(this);
        }
    }

    // Recover from the bug reported at https://github.com/transmission/transmission/issues/6899
    if (is_done() && date_done_ == time_t{})
    {
        date_done_ = now_sec;
    }
}

void tr_torrent::set_metainfo(tr_torrent_metainfo tm)
{
    TR_ASSERT(!has_metainfo());
    metainfo_ = std::move(tm);
    on_metainfo_updated();
    recalculate_file_order();

    got_metainfo_.emit(this);
    session->onMetadataCompleted(this);
    set_dirty();
    mark_edited();

    on_metainfo_completed();
    this->on_announce_list_changed();
}

tr_torrent* tr_torrentNew(tr_ctor* ctor, tr_torrent** setme_duplicate_of)
{
    TR_ASSERT(ctor != nullptr);
    auto* const session = ctor->session();
    TR_ASSERT(session != nullptr);

    // is the metainfo valid?
    auto metainfo = ctor->steal_metainfo();
    if (std::empty(metainfo.info_hash_string()))
    {
        return nullptr;
    }

    // is it a duplicate?
    if (auto* const duplicate_of = session->torrents().get(metainfo.info_hash()); duplicate_of != nullptr)
    {
        if (setme_duplicate_of != nullptr)
        {
            *setme_duplicate_of = duplicate_of;
        }

        return nullptr;
    }

    auto* const tor = new tr_torrent{ std::move(metainfo) };
    tor->verify_done_callback_ = ctor->steal_verify_done_callback();
    tor->init(*ctor);
    return tor;
}

// --- Location (see torrent-location.cc: set_location, find_file, has_any_local_data, C API)

void tr_torrentChangeMyPort(tr_torrent* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    if (tor->is_running())
    {
        tr_announcerChangeMyPort(tor);
    }
}

// ---

namespace
{
namespace manual_update_helpers
{
void torrentManualUpdateImpl(tr_torrent* const tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    if (tor->is_running())
    {
        tr_announcerManualAnnounce(tor);
    }
}
} // namespace manual_update_helpers
} // namespace

void tr_torrentManualUpdate(tr_torrent* tor)
{
    using namespace manual_update_helpers;

    TR_ASSERT(tr_isTorrent(tor));

    tor->session->run_in_session_thread(torrentManualUpdateImpl, tor);
}

void tr_torrentSetLastPlayedDate(tr_torrent* tor, time_t date)
{
    TR_ASSERT(tr_isTorrent(tor));
    tor->set_date_last_played(date);
}

bool tr_torrentCanManualUpdate(tr_torrent const* tor)
{
    return tr_isTorrent(tor) && tor->is_running() && tr_announcerCanManualAnnounce(tor);
}

// --- Stats and file views (see torrent-stats.cc)

size_t tr_torrentWebseedCount(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->webseed_count();
}

tr_tracker_view tr_torrentTracker(tr_torrent const* tor, size_t i)
{
    return tr_announcerTracker(tor, i);
}

size_t tr_torrentTrackerCount(tr_torrent const* tor)
{
    return tr_announcerTrackerCount(tor);
}

tr_torrent_view tr_torrentView(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    auto ret = tr_torrent_view{};
    ret.name = tor->name().c_str();
    ret.hash_string = tor->info_hash_string().c_str();
    ret.comment = tor->comment().c_str();
    ret.creator = tor->creator().c_str();
    ret.source = tor->source().c_str();
    ret.total_size = tor->total_size();
    ret.date_created = tor->date_created();
    ret.piece_size = tor->piece_size();
    ret.n_pieces = tor->piece_count();
    ret.is_private = tor->is_private();
    ret.is_folder = tor->file_count() > 1 || (tor->file_count() == 1 && tr_strv_contains(tor->file_subpath(0), '/'));

    return ret;
}

std::string tr_torrentFilename(tr_torrent const* tor)
{
    return std::string{ tor->torrent_file() };
}

size_t tr_torrentFilenameToBuf(tr_torrent const* tor, char* buf, size_t buflen)
{
    return tr_strv_to_buf(tr_torrentFilename(tor), buf, buflen);
}

// ---

tr_peer_stat* tr_torrentPeers(tr_torrent const* tor, size_t* peer_count)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tr_peerMgrPeerStats(tor, peer_count);
}

void tr_torrentPeersFree(tr_peer_stat* peer_stats, size_t /*peer_count*/)
{
    delete[] peer_stats;
}

void tr_torrentAvailability(tr_torrent const* tor, int8_t* tab, int size)
{
    TR_ASSERT(tr_isTorrent(tor));

    if (tab != nullptr && size > 0)
    {
        tr_peerMgrTorrentAvailability(tor, tab, size);
    }
}

void tr_torrentAmountFinished(tr_torrent const* tor, float* tabs, int n_tabs)
{
    tor->amount_done_bins(tabs, n_tabs);
}

// --- Start/Stop Callback

void tr_torrentStart(tr_torrent* tor)
{
    if (tr_isTorrent(tor))
    {
        tor->start_when_stable_ = true;
        tor->start(false /*bypass_queue*/, {});
    }
}

void tr_torrentStartNow(tr_torrent* tor)
{
    if (tr_isTorrent(tor))
    {
        tor->start_when_stable_ = true;
        tor->start(true /*bypass_queue*/, {});
    }
}

// ---

void tr_torrentVerify(tr_torrent* tor)
{
    tor->session->run_in_session_thread(
        [tor, session = tor->session, tor_id = tor->id()]()
        {
            TR_ASSERT(session->am_in_session_thread());
            auto const lock = session->unique_lock();

            if (tor != session->torrents().get(tor_id) || tor->is_deleting_)
            {
                return;
            }

            session->verify_remove(tor);

            if (!tor->has_metainfo())
            {
                return;
            }

            if (tor->is_running())
            {
                tor->stop_now();
            }

            if (did_files_disappear(tor))
            {
                tor->error().set_local_error(
                    _("Paused torrent as no data was found! Ensure your drives are connected or use \"Set Location\", "
                      "then use \"Verify Local Data\" again. To re-download, start the torrent."));
                tor->start_when_stable_ = false;
            }

            session->verify_add(tor);
        });
}

void tr_torrent::save_resume_file()
{
    if (!is_dirty())
    {
        return;
    }

    set_dirty(false);
    auto helper = ResumeHelper{ *this };
    tr_resume::save(this, helper);
}

// --- Completeness

namespace
{
namespace completeness_helpers
{
[[nodiscard]] constexpr char const* get_completion_string(int type)
{
    switch (type)
    {
    case TR_PARTIAL_SEED:
        /* Translators: this is a minor point that's safe to skip over, but FYI:
           "Complete" and "Done" are specific, different terms in Transmission:
           "Complete" means we've downloaded every file in the torrent.
           "Done" means we're done downloading the files we wanted, but NOT all
           that exist */
        return "Done";

    case TR_SEED:
        return "Complete";

    default:
        return "Incomplete";
    }
}
} // namespace completeness_helpers
} // namespace

void tr_torrent::create_empty_files() const
{
    auto const base = current_dir();
    TR_ASSERT(!std::empty(base));
    if (!has_metainfo() || std::empty(base))
    {
        return;
    }

    auto const file_count = this->file_count();
    for (tr_file_index_t file_index = 0U; file_index < file_count; ++file_index)
    {
        if (file_size(file_index) != 0U || !file_is_wanted(file_index) || find_file(file_index))
        {
            continue;
        }

        // torrent contains a wanted zero-bytes file and that file isn't on disk yet.
        // We attempt to create that file.
        auto filename = tr_pathbuf{};
        auto const& subpath = file_subpath(file_index);
        filename.assign(base, '/', subpath);

        // create subfolders, if any
        auto dir = tr_pathbuf{ filename.sv() };
        dir.popdir();
        tr_sys_dir_create(dir, TR_SYS_DIR_CREATE_PARENTS, 0777);

        // create the file
        if (auto const fd = tr_sys_file_open(filename, TR_SYS_FILE_WRITE | TR_SYS_FILE_CREATE | TR_SYS_FILE_SEQUENTIAL, 0666);
            fd != TR_BAD_SYS_FILE)
        {
            tr_sys_file_close(fd);
        }
    }
}

void tr_torrent::recheck_completeness()
{
    using namespace completeness_helpers;

    auto const lock = unique_lock();

    needs_completeness_check_ = false;

    if (auto const new_completeness = completion_.status(); completeness_ != new_completeness)
    {
        bool const recent_change = bytes_downloaded_.during_this_session() != 0U;
        bool const was_running = is_running();

        if (new_completeness != TR_LEECH && was_running && session->shouldFullyVerifyCompleteTorrents())
        {
            tr_torrentVerify(this);
            return;
        }

        tr_logAddTraceTor(
            this,
            fmt::format(
                "State changed from {} to {}",
                get_completion_string(completeness_),
                get_completion_string(new_completeness)));

        auto const was_done = is_done();
        completeness_ = new_completeness;
        auto const is_now_done = is_done();

        if (is_now_done)
        {
            session->close_torrent_files(id());

            if (recent_change)
            {
                // https://www.bittorrent.org/beps/bep_0003.html
                // ...and one using completed is sent when the download is complete.
                // No completed is sent if the file was complete when started.
                tr_announcerTorrentCompleted(this);
            }
            date_done_ = tr_time();

            if (current_dir() == incomplete_dir())
            {
                set_location(download_dir(), true, nullptr);
            }

            done_.emit(this, recent_change);
        }
        else if (was_done && !is_now_done && was_running)
        {
            // Transitioning from done to leech - recreate wishlist if torrent is running
            tr_peerMgrEnsureWishlist(this);
        }

        session->onTorrentCompletenessChanged(this, completeness_, was_running);

        set_dirty();
        mark_changed();

        if (is_done())
        {
            save_resume_file();
            callScriptIfEnabled(this, TR_SCRIPT_ON_TORRENT_DONE);
        }
    }
}

// --- File DND

void tr_torrentSetFileDLs(tr_torrent* tor, tr_file_index_t const* files, tr_file_index_t n_files, bool wanted)
{
    TR_ASSERT(tr_isTorrent(tor));

    tor->set_files_wanted(files, n_files, wanted);
}

// ---

void tr_torrent::set_labels(labels_t const& new_labels)
{
    auto const lock = unique_lock();
    labels_.clear();

    for (auto label : new_labels)
    {
        if (std::find(std::begin(labels_), std::end(labels_), label) == std::end(labels_))
        {
            labels_.push_back(label);
        }
    }
    labels_.shrink_to_fit();
    set_dirty();
    mark_edited();
}

// ---

void tr_torrent::set_bandwidth_group(std::string_view group_name) noexcept
{
    group_name = tr_strv_strip(group_name);

    auto const lock = this->unique_lock();

    if (std::empty(group_name))
    {
        this->bandwidth_group_ = tr_interned_string{};
        this->bandwidth().set_parent(&this->session->top_bandwidth_);
    }
    else
    {
        this->bandwidth_group_ = group_name;
        this->bandwidth().set_parent(&this->session->getBandwidthGroup(group_name));
    }

    this->set_dirty();
}

// ---

tr_priority_t tr_torrentGetPriority(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->get_priority();
}

void tr_torrentSetPriority(tr_torrent* const tor, tr_priority_t const priority)
{
    TR_ASSERT(tr_isTorrent(tor));
    TR_ASSERT(tr_isPriority(priority));

    if (tor->bandwidth().get_priority() != priority)
    {
        tor->bandwidth().set_priority(priority);

        tor->set_dirty();
    }
}

// ---

void tr_torrentSetPeerLimit(tr_torrent* tor, uint16_t max_connected_peers)
{
    TR_ASSERT(tr_isTorrent(tor));

    tor->set_peer_limit(max_connected_peers);
}

uint16_t tr_torrentGetPeerLimit(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->peer_limit();
}

// ---

tr_block_span_t tr_torrent::block_span_for_file(tr_file_index_t const file) const noexcept
{
    auto const [begin_byte, end_byte] = byte_span_for_file(file);

    // N.B. If the last file in the torrent is 0 bytes, and the torrent size is a multiple of block size,
    // then the computed block index will be past-the-end. We handle this with std::min.
    auto const begin_block = std::min(byte_loc(begin_byte).block, block_count() - 1U);

    if (begin_byte >= end_byte) // 0-byte file
    {
        return { begin_block, begin_block + 1 };
    }

    auto const final_block = byte_loc(end_byte - 1).block;
    auto const end_block = final_block + 1;
    return { begin_block, end_block };
}

// ---

void tr_torrent::set_file_priorities(tr_file_index_t const* files, tr_file_index_t file_count, tr_priority_t priority)
{
    if (std::any_of(
            files,
            files + file_count,
            [this, priority](tr_file_index_t file) { return priority != file_priorities_.file_priority(file); }))
    {
        file_priorities_.set(files, file_count, priority);
        priority_changed_.emit(this, files, file_count, priority);
        set_dirty();
        mark_changed();
    }
}

// ---

bool tr_torrent::check_piece(tr_piece_index_t const piece) const
{
    auto const pass = tr_ioTestPiece(*this, piece);
    tr_logAddTraceTor(this, fmt::format("[LAZY] tr_torrent.checkPiece tested piece {}, pass=={}", piece, pass));
    return pass;
}

// --- Announce (see torrent-announce.cc)

uint64_t tr_torrentGetBytesLeftToAllocate(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    uint64_t bytes_left = 0;

    for (tr_file_index_t i = 0, n = tor->file_count(); i < n; ++i)
    {
        if (auto const wanted = tor->files_wanted_.file_wanted(i); !wanted)
        {
            continue;
        }

        auto const length = tor->file_size(i);
        bytes_left += length;

        auto const found = tor->find_file(i);
        if (found)
        {
            bytes_left -= found->size;
        }
    }

    return bytes_left;
}

// ---

std::string_view tr_torrent::primary_mime_type() const
{
    // count up how many bytes there are for each mime-type in the torrent
    // NB: get_mime_type_for_filename() always returns the same ptr for a
    // mime_type, so its raw pointer can be used as a key.
    auto size_per_mime_type = small::unordered_map<std::string_view, size_t, 256U>{};
    for (tr_file_index_t i = 0, n = this->file_count(); i < n; ++i)
    {
        auto const mime_type = tr_get_mime_type_for_filename(this->file_subpath(i));
        size_per_mime_type[mime_type] += this->file_size(i);
    }

    if (std::empty(size_per_mime_type))
    {
        // https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
        // application/octet-stream is the default value for all other cases.
        // An unknown file type should use this type.
        auto constexpr Fallback = "application/octet-stream"sv;
        return Fallback;
    }

    auto const it = std::max_element(
        std::begin(size_per_mime_type),
        std::end(size_per_mime_type),
        [](auto const& a, auto const& b) { return a.second < b.second; });
    return it->first;
}

// ---

void tr_torrent::on_file_completed(tr_file_index_t const file)
{
    /* close the file so that we can reopen in read-only mode as needed */
    session->close_torrent_file(*this, file);

    /* now that the file is complete and closed, we can start watching its
     * mtime timestamp for changes to know if we need to reverify pieces */
    file_mtimes_[file] = tr_time();

    /* if the torrent's current filename isn't the same as the one in the
     * metadata -- for example, if it had the ".part" suffix appended to
     * it until now -- then rename it to match the one in the metadata */
    update_file_path(file, true);
}

void tr_torrent::on_piece_completed(tr_piece_index_t const piece)
{
    piece_completed_.emit(this, piece);

    // bookkeeping
    set_needs_completeness_check();

    // Update consecutive progress cache for affected files
    update_file_consecutive_progress(piece);

    // in sequential mode, flush files as soon a piece
    // is completed to let other programs read the written data
    if (is_sequential_download())
    {
        session->flush_torrent_files(id());
    }

    // if this piece completes any file, invoke the fileCompleted func for it
    for (auto [file, file_end] = fpm_.file_span_for_piece(piece); file < file_end; ++file)
    {
        if (has_file(file))
        {
            on_file_completed(file);
        }
    }
}

void tr_torrent::on_piece_failed(tr_piece_index_t const piece)
{
    tr_logAddDebugTor(this, fmt::format("Piece {}, which was just downloaded, failed its checksum test", piece));

    auto const n = piece_size(piece);
    bytes_corrupt_ += n;
    bytes_downloaded_.reduce(n);
    got_bad_piece_.emit(this, piece);
    set_has_piece(piece, false);
}

void tr_torrent::on_block_received(tr_block_index_t const block)
{
    TR_ASSERT(session->am_in_session_thread());

    if (has_block(block))
    {
        tr_logAddDebugTor(this, "we have this block already...");
        bytes_downloaded_.reduce(block_size(block));
        return;
    }

    set_dirty();

    completion_.add_block(block);

    auto const block_loc = this->block_loc(block);
    auto const first_piece = block_loc.piece;
    auto const last_piece = byte_loc(block_loc.byte + block_size(block) - 1).piece;
    for (auto piece = first_piece; piece <= last_piece; ++piece)
    {
        if (!has_piece(piece))
        {
            continue;
        }

        if (check_piece(piece))
        {
            on_piece_completed(piece);
        }
        else
        {
            on_piece_failed(piece);
        }
    }
}

// ---

std::string tr_torrentFindFile(tr_torrent const* tor, tr_file_index_t file_num)
{
    auto const found = tor->find_file(file_num);
    return std::string{ found ? found->filename().sv() : ""sv };
}

size_t tr_torrentFindFileToBuf(tr_torrent const* tor, tr_file_index_t file_num, char* buf, size_t buflen)
{
    return tr_strv_to_buf(tr_torrentFindFile(tor, file_num), buf, buflen);
}

void tr_torrent::set_download_dir(std::string_view path, bool is_new_torrent)
{
    download_dir_ = path;
    mark_edited();
    set_dirty();
    refresh_current_dir();

    if (is_new_torrent)
    {
        if (session->shouldFullyVerifyAddedTorrents() || !is_new_torrent_a_seed())
        {
            tr_torrentVerify(this);
        }
        else
        {
            completion_.set_has_all();
            recheck_completeness();
            date_done_ = date_added_; // Must be after recheck_completeness()
        }
    }
    else if (error_.error_type() == TR_STAT_LOCAL_ERROR && !set_local_error_if_files_disappeared(this))
    {
        error_.clear();
    }
}

// decide whether we should be looking for files in downloadDir or incompleteDir
void tr_torrent::refresh_current_dir()
{
    auto dir = tr_interned_string{};

    if (std::empty(incomplete_dir()))
    {
        dir = download_dir();
    }
    else if (!has_metainfo()) // no files to find
    {
        dir = incomplete_dir();
    }
    else
    {
        auto const found = find_file(0);
        dir = found ? tr_interned_string{ found->base() } : incomplete_dir();
    }

    TR_ASSERT(!std::empty(dir));
    TR_ASSERT(dir == download_dir() || dir == incomplete_dir());

    current_dir_ = dir;
}

// --- Rename (see torrent-rename.cc)

void tr_torrentSetFilePriorities(
    tr_torrent* tor,
    tr_file_index_t const* files,
    tr_file_index_t file_count,
    tr_priority_t priority)
{
    tor->set_file_priorities(files, file_count, priority);
}

bool tr_torrentHasMetadata(tr_torrent const* tor)
{
    return tor->has_metainfo();
}

void tr_torrent::mark_edited()
{
    auto const now = tr_time();
    bump_date_edited(now);
    bump_date_changed(now);
}

void tr_torrent::mark_changed()
{
    this->bump_date_changed(tr_time());
}

[[nodiscard]] bool tr_torrent::ensure_piece_is_checked(tr_piece_index_t piece)
{
    TR_ASSERT(piece < this->piece_count());

    if (is_piece_checked(piece))
    {
        return true;
    }

    bool const checked = check_piece(piece);
    mark_changed();
    set_dirty();

    checked_pieces_.set(piece, checked);
    return checked;
}
