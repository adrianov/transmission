// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>

namespace libtransmission
{

/** Per-host circuit breaker for tracker announces (rate limits, 5xx, UDP timeouts). */
class HostTrackerRegistry
{
public:
    enum class State : uint8_t
    {
        Closed,
        Open,
        HalfOpen,
    };

    struct AnnounceOutcome
    {
        bool success = false;
        bool rate_limited = false;
        bool server_error = false;
        bool timed_out = false;
        bool is_udp = false;
    };

    /** @return false when the host queue is paused (open, half-open probe, or stagger). */
    [[nodiscard]] bool canAnnounce(std::string_view host);

    void onAnnounceSent(std::string_view host);

    /** Updates host state; @return true when the announce event should be re-queued at tier front. */
    bool noteAnnounceResult(std::string_view host, AnnounceOutcome outcome);

    [[nodiscard]] bool isBlocked(std::string_view host) const;

    [[nodiscard]] bool empty() const;

    void clear();

private:
    struct HostState
    {
        State state = State::Closed;
        std::chrono::steady_clock::time_point blocked_until{};
        std::chrono::steady_clock::time_point next_allowed{};
        int consecutive_timeouts = 0;
        bool probe_in_flight = false;
    };

    static auto constexpr BlockDuration = std::chrono::seconds{ 360 };
    static auto constexpr MinStagger = std::chrono::seconds{ 3 };
    static auto constexpr MaxStagger = std::chrono::seconds{ 5 };
    static auto constexpr UdpTimeoutLimit = 3;

    [[nodiscard]] static std::chrono::milliseconds staggerDelay();

    void tripCircuitLocked(HostState& state);

    mutable std::mutex mutex_;
    std::unordered_map<std::string, HostState> hosts_;
};

} // namespace libtransmission
