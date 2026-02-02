// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <optional>
#include <vector>

#include "libtransmission/transmission.h"
#include "libtransmission/bandwidth.h"
#include "libtransmission/peer-common.h"
#include "libtransmission/peer-mgr.h"
#include "libtransmission/torrent.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-macros.h"
#include "libtransmission/utils.h"

using namespace libtransmission::Values;

bool tr_torrentGetSeedRatioBytes(tr_torrent const* tor, uint64_t* setme_left, uint64_t* setme_goal)
{
    bool seed_ratio_applies = false;

    TR_ASSERT(tr_isTorrent(tor));

    if (auto const seed_ratio = tor->effective_seed_ratio(); seed_ratio)
    {
        auto const uploaded = tor->bytes_uploaded_.ever();
        auto const baseline = tor->size_when_done();
        auto const goal = baseline * *seed_ratio;

        if (setme_left != nullptr)
        {
            *setme_left = goal > uploaded ? goal - uploaded : 0;
        }

        if (setme_goal != nullptr)
        {
            *setme_goal = goal;
        }

        seed_ratio_applies = tor->is_done();
    }

    return seed_ratio_applies;
}

bool tr_torrentIsSeedRatioDone(tr_torrent const* tor)
{
    auto bytes_left = uint64_t{};
    return tr_torrentGetSeedRatioBytes(tor, &bytes_left, nullptr) && bytes_left == 0;
}

bool tr_torrentGetSeedRatio(tr_torrent const* const tor, double* ratio)
{
    TR_ASSERT(tr_isTorrent(tor));

    auto const val = tor->effective_seed_ratio();

    if (ratio != nullptr && val)
    {
        *ratio = *val;
    }

    return val.has_value();
}

tr_stat tr_torrent::stats() const
{
    static auto constexpr IsStalled = [](tr_torrent const* const tor, std::optional<time_t> idle_secs)
    {
        return tor->session->queueStalledEnabled() &&
            idle_secs > static_cast<time_t>(tor->session->queueStalledMinutes() * 60U);
    };

    auto const lock = unique_lock();

    auto const now_msec = tr_time_msec();
    auto const now_sec = tr_time();

    auto const swarm_stats = this->swarm != nullptr ? tr_swarmGetStats(this->swarm) : tr_swarm_stats{};
    auto const activity = this->activity();
    auto const idle_seconds = this->idle_seconds(now_sec);

    auto stats = tr_stat{};

    stats.id = this->id();
    stats.activity = activity;
    stats.error = this->error().error_type();
    stats.queuePosition = queue_position();
    stats.idleSecs = idle_seconds ? *idle_seconds : time_t{ -1 };
    stats.isStalled = IsStalled(this, idle_seconds);
    stats.errorString = this->error().errmsg().c_str();

    stats.peersConnected = swarm_stats.peer_count;
    stats.peersSendingToUs = swarm_stats.active_peer_count[TR_DOWN];
    stats.peersGettingFromUs = swarm_stats.active_peer_count[TR_UP];
    stats.webseedsSendingToUs = swarm_stats.active_webseed_count;

    for (int i = 0; i < TR_PEER_FROM_N_TYPES; i++)
    {
        stats.peersFrom[i] = swarm_stats.peer_from_count[i];
        stats.knownPeersFrom[i] = swarm_stats.known_peer_from_count[i];
    }

    auto const piece_upload_speed = bandwidth().get_piece_speed(now_msec, TR_UP);
    stats.pieceUploadSpeed_KBps = piece_upload_speed.count(Speed::Units::KByps);
    auto const piece_download_speed = bandwidth().get_piece_speed(now_msec, TR_DOWN);
    stats.pieceDownloadSpeed_KBps = piece_download_speed.count(Speed::Units::KByps);

    stats.percentComplete = this->completion_.percent_complete();
    stats.metadataPercentComplete = get_metadata_percent();

    stats.percentDone = this->completion_.percent_done();
    stats.leftUntilDone = this->completion_.left_until_done();
    stats.sizeWhenDone = this->completion_.size_when_done();

    auto const verify_progress = this->verify_progress();
    stats.recheckProgress = verify_progress.value_or(0.0);
    stats.activityDate = this->date_active_;
    stats.addedDate = this->date_added_;
    stats.doneDate = this->date_done_;
    stats.editDate = this->date_edited_;
    stats.startDate = this->date_started_;
    stats.lastPlayedDate = this->date_last_played_;
    stats.secondsSeeding = this->seconds_seeding(now_sec);
    stats.secondsDownloading = this->seconds_downloading(now_sec);

    stats.corruptEver = this->bytes_corrupt_.ever();
    stats.downloadedEver = this->bytes_downloaded_.ever();
    stats.uploadedEver = this->bytes_uploaded_.ever();
    stats.haveValid = this->completion_.has_valid();
    stats.haveUnchecked = this->has_total() - stats.haveValid;
    stats.desiredAvailable = tr_peerMgrGetDesiredAvailable(this);

    stats.ratio = tr_getRatio(stats.uploadedEver, this->size_when_done());

    auto seed_ratio_bytes_left = uint64_t{};
    auto seed_ratio_bytes_goal = uint64_t{};
    bool const seed_ratio_applies = tr_torrentGetSeedRatioBytes(this, &seed_ratio_bytes_left, &seed_ratio_bytes_goal);

    stats.eta = TR_ETA_NOT_AVAIL;
    stats.etaIdle = TR_ETA_NOT_AVAIL;
    if (activity == TR_STATUS_DOWNLOAD)
    {
        if (auto const eta_speed_byps = eta_speed_.update(now_msec, piece_download_speed).base_quantity(); eta_speed_byps == 0U)
        {
            stats.eta = TR_ETA_UNKNOWN;
        }
        else if (stats.leftUntilDone <= stats.desiredAvailable || webseed_count() >= 1U)
        {
            stats.eta = stats.leftUntilDone / eta_speed_byps;
        }
    }
    else if (activity == TR_STATUS_SEED)
    {
        auto const eta_speed_byps = eta_speed_.update(now_msec, piece_upload_speed).base_quantity();

        if (seed_ratio_applies)
        {
            stats.eta = eta_speed_byps == 0U ? static_cast<time_t>(TR_ETA_UNKNOWN) : seed_ratio_bytes_left / eta_speed_byps;
        }

        if (eta_speed_byps < 1U)
        {
            if (auto const secs_left = idle_seconds_left(now_sec); secs_left)
            {
                stats.etaIdle = *secs_left;
            }
        }
    }

    stats.finished = this->finished_seeding_by_idle_ ||
        (seed_ratio_applies && seed_ratio_bytes_left == 0 && stats.haveValid != 0);

    if (!seed_ratio_applies || stats.finished)
    {
        stats.seedRatioPercentDone = 1.0F;
    }
    else if (seed_ratio_bytes_goal == 0)
    {
        stats.seedRatioPercentDone = 0.0F;
    }
    else
    {
        stats.seedRatioPercentDone = float(seed_ratio_bytes_goal - seed_ratio_bytes_left) / seed_ratio_bytes_goal;
    }

    TR_ASSERT(stats.sizeWhenDone <= this->total_size());
    TR_ASSERT(stats.leftUntilDone <= stats.sizeWhenDone);
    TR_ASSERT(stats.desiredAvailable <= stats.leftUntilDone);
    return stats;
}

tr_stat const* tr_torrentStat(tr_torrent* const tor)
{
    tor->stats_ = tor->stats();
    return &tor->stats_;
}

std::vector<tr_stat const*> tr_torrentStat(tr_torrent* const* torrents, size_t n_torrents)
{
    auto ret = std::vector<tr_stat const*>{};

    if (n_torrents != 0U)
    {
        ret.reserve(n_torrents);

        auto const lock = torrents[0]->unique_lock();

        for (size_t idx = 0U; idx != n_torrents; ++idx)
        {
            tr_torrent* const tor = torrents[idx];
            tor->stats_ = tor->stats();
            ret.emplace_back(&tor->stats_);
        }
    }

    return ret;
}

tr_file_view tr_torrentFile(tr_torrent const* tor, tr_file_index_t file)
{
    TR_ASSERT(tr_isTorrent(tor));

    auto const& subpath = tor->file_subpath(file);
    auto const priority = tor->file_priorities_.file_priority(file);
    auto const wanted = tor->files_wanted_.file_wanted(file);
    auto const length = tor->file_size(file);
    auto const [begin, end] = tor->piece_span_for_file(file);

    if (tor->is_seed() || length == 0)
    {
        return { subpath.c_str(), length, length, 1.0, begin, end, priority, wanted };
    }

    auto const have = tor->completion_.count_has_bytes_in_span(tor->byte_span_for_file(file));
    return { subpath.c_str(), have, length, have >= length ? 1.0 : have / double(length), begin, end, priority, wanted };
}

size_t tr_torrentFileCount(tr_torrent const* torrent)
{
    TR_ASSERT(tr_isTorrent(torrent));

    return torrent->file_count();
}

float tr_torrentFileConsecutiveProgress(tr_torrent const* torrent, tr_file_index_t file)
{
    TR_ASSERT(tr_isTorrent(torrent));

    return torrent->file_consecutive_progress(file);
}

tr_webseed_view tr_torrentWebseed(tr_torrent const* tor, size_t nth)
{
    return tr_peerMgrWebseed(tor, nth);
}
