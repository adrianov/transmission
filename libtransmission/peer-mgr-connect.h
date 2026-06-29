// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#ifndef LIBTRANSMISSION_PEER_MODULE
#error only the libtransmission peer module should #include this header.
#endif

#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

#include <small/vector.hpp>

#include "libtransmission/net.h"
#include "libtransmission/torrents.h"

class tr_swarm;
struct tr_peerMgr;
class tr_peer_info;
struct tr_torrent;

namespace peer_mgr_connect
{

// Peers to connect immediately on the first tracker response (libtorrent: torrent_connect_boost).
inline auto constexpr ConnectBoostCount = size_t{ 10U };

// Outbound candidate queue capacity matches tr_peerMgr::OutboundCandidateListCapacity.
inline auto constexpr OutboundCandidateListCapacity = size_t{ 36U };

using OutboundCandidates = small::max_size_vector<std::pair<tr_torrent_id_t, tr_socket_address>, OutboundCandidateListCapacity>;

// Per-torrent peer limit, lowered to the dynamic limit when speed stats found a better value.
[[nodiscard]] size_t effective_peer_limit(tr_swarm const* swarm);

[[nodiscard]] uint64_t peer_candidate_score(tr_torrent const& tor, tr_peer_info const& peer_info, uint8_t salt);

[[nodiscard]] bool is_peer_candidate(tr_torrent const& tor, tr_peer_info const& peer_info, time_t now);

void get_peer_candidates(size_t global_peer_limit, tr_torrents& torrents, OutboundCandidates& setme);

// Caller must hold the session lock. Connects to up to max_attempts peers in one swarm.
void bootstrap_swarm(tr_peerMgr* mgr, tr_swarm* swarm, size_t max_attempts);

void initiate_outbound(tr_peerMgr* mgr, tr_swarm* swarm, tr_peer_info& peer_info);

} // namespace peer_mgr_connect
