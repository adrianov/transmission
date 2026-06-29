// Included from peer-mgr.cc after peer-mgr-connect-score.inc (same namespace).

void get_peer_candidates(size_t const global_peer_limit, tr_torrents& torrents, OutboundCandidates& setme)
{
    struct peer_candidate
    {
        peer_candidate() = default;

        peer_candidate(uint64_t score_in, tr_torrent const* const tor_in, tr_peer_info const* const peer_info_in)
            : score{ score_in }
            , tor{ tor_in }
            , peer_info{ peer_info_in }
        {
        }

        uint64_t score;
        tr_torrent const* tor;
        tr_peer_info const* peer_info;
    };

    setme.clear();

    auto const now = tr_time();
    auto const now_msec = tr_time_msec();

    // Reserve slots for incoming connections (#2609) and bootstrapping swarms with zero peers.
    auto const connected = tr_peerMsgs::size();
    auto const incoming_reserve = std::max(static_cast<size_t>(global_peer_limit * 0.05), size_t{ 10U });
    auto const at_outbound_cap = connected >= global_peer_limit - incoming_reserve;

    auto candidates = std::vector<peer_candidate>{};
    candidates.reserve(tr_peer_info::known_connectable_count());

    auto salter = tr_salt_shaker{};
    for (auto* const tor : torrents)
    {
        auto* const swarm = tor->swarm;

        if (!swarm->is_running)
        {
            continue;
        }

        if (at_outbound_cap && !swarm->peers.empty())
        {
            continue;
        }

        bool const seeding = tor->is_done();
        if (seeding && swarm->is_all_upload_only() && !tor->allows_pex())
        {
            continue;
        }

        if (effective_peer_limit(swarm) <= swarm->peerCount())
        {
            continue;
        }

        if (seeding && tor->bandwidth().is_maxed_out(TR_UP, now_msec))
        {
            continue;
        }

        for (auto const& [socket_address, peer_info] : swarm->connectable_pool)
        {
            TR_ASSERT(socket_address == peer_info->listen_socket_address());
            if (is_peer_candidate(*tor, *peer_info, now))
            {
                candidates.emplace_back(peer_candidate_score(*tor, *peer_info, salter()), tor, peer_info.get());
            }
        }
    }

    auto const n_keep = std::min(OutboundCandidates::requested_inline_size, std::size(candidates));
    std::partial_sort(std::begin(candidates),
                      std::begin(candidates) + n_keep,
                      std::end(candidates),
                      [](auto const& a, auto const& b) { return a.score < b.score; });
    candidates.resize(n_keep);

    for (auto it = std::crbegin(candidates), end = std::crend(candidates); it != end; ++it)
    {
        setme.emplace_back(it->tor->id(), it->peer_info->listen_socket_address());
    }
}

void bootstrap_swarm(tr_peerMgr* const mgr, tr_swarm* const swarm, size_t max_attempts)
{
    TR_ASSERT(swarm != nullptr);
    TR_ASSERT(mgr != nullptr);

    if (!swarm->is_running || swarm->tor->is_done())
    {
        return;
    }

    if (effective_peer_limit(swarm) <= swarm->peerCount())
    {
        return;
    }

    auto const now = tr_time();

    struct scored_peer
    {
        tr_peer_info* peer_info;
        uint64_t score;
    };

    auto candidates = std::vector<scored_peer>{};
    candidates.reserve(swarm->connectable_pool.size());

    for (auto const& [socket_address, peer_info] : swarm->connectable_pool)
    {
        TR_ASSERT(socket_address == peer_info->listen_socket_address());
        if (is_peer_candidate(*swarm->tor, *peer_info, now))
        {
            candidates.push_back({ peer_info.get(), peer_candidate_score(*swarm->tor, *peer_info, 0U) });
        }
    }

    if (std::empty(candidates))
    {
        return;
    }

    auto const n_keep = std::min(max_attempts, std::size(candidates));
    std::partial_sort(std::begin(candidates),
                      std::begin(candidates) + n_keep,
                      std::end(candidates),
                      [](auto const& a, auto const& b) { return a.score < b.score; });

    for (size_t i = 0; i < n_keep; ++i)
    {
        initiate_outbound(mgr, swarm, *candidates[i].peer_info);
    }
}

} // namespace peer_mgr_connect
