// Included from peer-mgr.cc after tr_swarm and handshake helpers are defined.

namespace peer_mgr_connect
{
[[nodiscard]] size_t effective_peer_limit(tr_swarm const* swarm)
{
    auto const configured = swarm->tor->peer_limit();
    return (swarm->dynamic_peer_limit > 0 && swarm->dynamic_peer_limit < configured) ? swarm->dynamic_peer_limit : configured;
}

namespace
{

[[nodiscard]] constexpr uint64_t add_val_to_key(uint64_t value, unsigned int width, uint64_t addme)
{
    value <<= width;
    value |= addme;
    return value;
}

} // namespace

[[nodiscard]] bool is_peer_candidate(tr_torrent const& tor, tr_peer_info const& peer_info, time_t const now)
{
    if (tor.is_done() && peer_info.is_upload_only() && !tor.allows_pex())
    {
        return false;
    }

    if (peer_info.is_in_use())
    {
        return false;
    }

    if (!peer_info.reconnect_interval_has_passed(now))
    {
        return false;
    }

    if (peer_info.is_blocklisted(tor.session->blocklist()))
    {
        return false;
    }

    if (peer_info.is_banned())
    {
        return false;
    }

    return true;
}

[[nodiscard]] uint64_t compose_candidate_score(CandidateKey const& key) noexcept
{
    auto score = uint64_t{};
    score = add_val_to_key(score, 1U, key.swarm_has_peers);
    score = add_val_to_key(score, 1U, key.had_fruitless);
    score = add_val_to_key(score, 32U, key.last_attempt_time);
    score = add_val_to_key(score, 2U, key.torrent_priority);
    score = add_val_to_key(score, 1U, key.not_started_recently);
    score = add_val_to_key(score, 1U, key.is_done);
    score = add_val_to_key(score, 1U, key.not_connectable);
    score = add_val_to_key(score, 1U, key.is_upload_only);
    score = add_val_to_key(score, 4U, key.from_best);
    score = add_val_to_key(score, 8U, key.salt);
    return score;
}

[[nodiscard]] uint64_t peer_candidate_score(tr_torrent const& tor, tr_peer_info const& peer_info, uint8_t const salt)
{
    auto key = CandidateKey{};

    // Prefer swarms with no connected peers yet (bootstrap).
    key.swarm_has_peers = tor.swarm->peers.empty() ? 0U : 1U;
    key.had_fruitless = peer_info.fruitless_connection_count() != 0U ? 1U : 0U;
    key.last_attempt_time = static_cast<uint64_t>(peer_info.connection_attempt_time());

    switch (tor.get_priority())
    {
    case TR_PRI_HIGH:
        key.torrent_priority = 0U;
        break;

    case TR_PRI_NORMAL:
        key.torrent_priority = 1U;
        break;

    case TR_PRI_LOW:
        key.torrent_priority = 2U;
        break;

    default:
        TR_ASSERT_MSG(false, "invalid priority");
        break;
    }

    key.not_started_recently = tor.started_recently(tr_time()) ? 0U : 1U;
    key.is_done = tor.is_done() ? 1U : 0U;
    key.not_connectable = peer_info.is_connectable().value_or(false) ? 0U : 1U;
    key.is_upload_only = peer_info.is_upload_only() ? 1U : 0U;
    key.from_best = peer_info.from_best();
    key.salt = salt;

    return compose_candidate_score(key);
}
