// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "libtransmission/file.h"
#include "libtransmission/session.h"
#include "libtransmission/transmission.h"
#include "libtransmission/torrent.h"

void tr_session_pause_downloads_if_low_disk_space(tr_session* session)
{
    constexpr uint64_t min_free = uint64_t{ 1 } << 30; // 1 GiB
    std::map<std::string, std::vector<tr_torrent*>, std::less<>> dir_to_active;
    for (auto* const tor : session->torrents())
    {
        auto const* const st = tr_torrentStat(tor);
        if (st == nullptr || st->activity != TR_STATUS_DOWNLOAD)
            continue;
        auto const* const dir = tr_torrentGetDownloadDir(tor);
        if (dir != nullptr && *dir != '\0')
            dir_to_active[dir].push_back(tor);
    }
    for (auto const& [path, to_pause] : dir_to_active)
    {
        auto const cap = tr_sys_path_get_capacity(path);
        if (!cap || cap->free < 0 || static_cast<uint64_t>(cap->free) >= min_free)
            continue;
        for (auto* tor : to_pause)
            tr_torrentStop(tor);
    }
}
