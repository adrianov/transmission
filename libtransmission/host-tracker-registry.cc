// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "libtransmission/host-tracker-registry.h"

#include <fmt/format.h>

#include "libtransmission/crypto-utils.h"
#include "libtransmission/log.h"

namespace libtransmission
{
namespace
{

using Clock = std::chrono::steady_clock;

bool isCircuitTripFailure(HostTrackerRegistry::AnnounceOutcome const& outcome)
{
    return outcome.rate_limited || outcome.server_error;
}

} // namespace

std::chrono::milliseconds HostTrackerRegistry::staggerDelay()
{
    auto const span = MaxStagger - MinStagger;
    auto const jitter = tr_rand_int(static_cast<unsigned>(span.count()) + 1U);
    return MinStagger + std::chrono::seconds{ jitter };
}

bool HostTrackerRegistry::canAnnounce(std::string_view const host)
{
    if (std::empty(host))
    {
        return true;
    }

    std::lock_guard const lock{ mutex_ };
    auto& state = hosts_[std::string{ host }];
    auto const now = Clock::now();

    if (state.state == State::Open)
    {
        if (now < state.blocked_until)
        {
            return false;
        }

        state.state = State::HalfOpen;
        state.probe_in_flight = false;
    }

    if (state.state == State::HalfOpen)
    {
        return !state.probe_in_flight;
    }

    return now >= state.next_allowed;
}

void HostTrackerRegistry::onAnnounceSent(std::string_view const host)
{
    if (std::empty(host))
    {
        return;
    }

    std::lock_guard const lock{ mutex_ };
    auto& state = hosts_[std::string{ host }];

    if (state.state == State::HalfOpen)
    {
        state.probe_in_flight = true;
    }

    state.next_allowed = Clock::now() + staggerDelay();
}

bool HostTrackerRegistry::noteAnnounceResult(std::string_view const host, AnnounceOutcome const outcome)
{
    if (std::empty(host))
    {
        return false;
    }

    std::lock_guard const lock{ mutex_ };
    auto& state = hosts_[std::string{ host }];

    if (outcome.success)
    {
        state.consecutive_timeouts = 0;
        state.state = State::Closed;
        state.probe_in_flight = false;
        return false;
    }

    if (state.state == State::HalfOpen)
    {
        tripCircuitLocked(state);
        tr_logAddInfo(fmt::format("Tracker host '{}' probe failed; pausing announces for 360 seconds", host));
        return true;
    }

    if (isCircuitTripFailure(outcome))
    {
        tripCircuitLocked(state);
        tr_logAddInfo(
            fmt::format("Tracker host '{}' rate-limited or returned server error; pausing announces for 360 seconds", host));
        return true;
    }

    if (outcome.timed_out && outcome.is_udp)
    {
        ++state.consecutive_timeouts;
        if (state.consecutive_timeouts >= UdpTimeoutLimit)
        {
            tripCircuitLocked(state);
            tr_logAddInfo(fmt::format("Tracker host '{}' had {} consecutive UDP timeouts; pausing announces for 360 seconds",
                                      host,
                                      UdpTimeoutLimit));
            return true;
        }
    }

    state.probe_in_flight = false;
    return false;
}

bool HostTrackerRegistry::isBlocked(std::string_view const host) const
{
    if (std::empty(host))
    {
        return false;
    }

    std::lock_guard const lock{ mutex_ };
    auto const it = hosts_.find(std::string{ host });
    if (it == std::end(hosts_))
    {
        return false;
    }

    auto const& state = it->second;
    if (state.state != State::Open)
    {
        return false;
    }

    return Clock::now() < state.blocked_until;
}

bool HostTrackerRegistry::empty() const
{
    std::lock_guard const lock{ mutex_ };
    return std::empty(hosts_);
}

void HostTrackerRegistry::clear()
{
    std::lock_guard const lock{ mutex_ };
    hosts_.clear();
}

void HostTrackerRegistry::tripCircuitLocked(HostState& state)
{
    state.state = State::Open;
    state.blocked_until = Clock::now() + BlockDuration;
    state.consecutive_timeouts = 0;
    state.probe_in_flight = false;
}

} // namespace libtransmission
