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

[[nodiscard]] uint64_t peer_candidate_score(tr_torrent const& tor, tr_peer_info const& peer_info, uint8_t const salt)
{
    auto i = uint64_t{};
    auto score = uint64_t{};

    // Prefer swarms with no connected peers yet (bootstrap).
    i = tor.swarm->peers.empty() ? 0U : 1U;
    score = add_val_to_key(score, 1U, i);

    i = peer_info.fruitless_connection_count() != 0U ? 1U : 0U;
    score = add_val_to_key(score, 1U, i);

    i = peer_info.connection_attempt_time();
    score = add_val_to_key(score, 32U, i);

    switch (tor.get_priority())
    {
    case TR_PRI_HIGH:
        i = 0;
        break;

    case TR_PRI_NORMAL:
        i = 1;
        break;

    case TR_PRI_LOW:
        i = 2;
        break;

    default:
        TR_ASSERT_MSG(false, "invalid priority");
        break;
    }

    score = add_val_to_key(score, 2U, i);

    i = tor.started_recently(tr_time()) ? 0 : 1;
    score = add_val_to_key(score, 1U, i);

    i = tor.is_done() ? 1 : 0;
    score = add_val_to_key(score, 1U, i);

    i = peer_info.is_connectable().value_or(false) ? 0 : 1;
    score = add_val_to_key(score, 1U, i);

    i = peer_info.is_upload_only() ? 1 : 0;
    score = add_val_to_key(score, 1U, i);

    score = add_val_to_key(score, 4U, peer_info.from_best());

    score = add_val_to_key(score, 8U, salt);

    return score;
}
