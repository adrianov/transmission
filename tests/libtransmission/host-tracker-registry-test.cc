// This file Copyright (C) Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "libtransmission/host-tracker-registry.h"

#include "gtest/gtest.h"

using namespace libtransmission;
using namespace std::literals;

TEST(HostTrackerRegistryTest, staggerDelayBetweenClosedAnnounces)
{
    HostTrackerRegistry registry;
    auto const host = "tracker.example.com"sv;

    EXPECT_TRUE(registry.canAnnounce(host));
    registry.onAnnounceSent(host);
    EXPECT_FALSE(registry.canAnnounce(host));
}

TEST(HostTrackerRegistryTest, rateLimitTripsCircuit)
{
    HostTrackerRegistry registry;
    auto const host = "tracker.example.com"sv;

    registry.onAnnounceSent(host);

    auto outcome = HostTrackerRegistry::AnnounceOutcome{};
    outcome.rate_limited = true;
    EXPECT_TRUE(registry.noteAnnounceResult(host, outcome));
    EXPECT_TRUE(registry.isBlocked(host));
    EXPECT_FALSE(registry.canAnnounce(host));
}

TEST(HostTrackerRegistryTest, udpTimeoutsTripAfterThirdFailure)
{
    HostTrackerRegistry registry;
    auto const host = "udp.tracker.example.com"sv;

    for (int i = 0; i < 2; ++i)
    {
        registry.onAnnounceSent(host);
        auto outcome = HostTrackerRegistry::AnnounceOutcome{};
        outcome.timed_out = true;
        outcome.is_udp = true;
        EXPECT_FALSE(registry.noteAnnounceResult(host, outcome));
        EXPECT_FALSE(registry.isBlocked(host));
    }

    registry.onAnnounceSent(host);
    auto outcome = HostTrackerRegistry::AnnounceOutcome{};
    outcome.timed_out = true;
    outcome.is_udp = true;
    EXPECT_TRUE(registry.noteAnnounceResult(host, outcome));
    EXPECT_TRUE(registry.isBlocked(host));
}

TEST(HostTrackerRegistryTest, successResetsCircuit)
{
    HostTrackerRegistry registry;
    auto const host = "tracker.example.com"sv;

    registry.onAnnounceSent(host);
    auto fail = HostTrackerRegistry::AnnounceOutcome{};
    fail.server_error = true;
    EXPECT_TRUE(registry.noteAnnounceResult(host, fail));

    registry.onAnnounceSent(host);
    auto success = HostTrackerRegistry::AnnounceOutcome{};
    success.success = true;
    EXPECT_FALSE(registry.noteAnnounceResult(host, success));
    EXPECT_FALSE(registry.isBlocked(host));
}

TEST(HostTrackerRegistryTest, clearRemovesHostState)
{
    HostTrackerRegistry registry;
    auto const host = "tracker.example.com"sv;

    registry.onAnnounceSent(host);
    auto fail = HostTrackerRegistry::AnnounceOutcome{};
    fail.server_error = true;
    registry.noteAnnounceResult(host, fail);
    EXPECT_TRUE(registry.isBlocked(host));

    registry.clear();
    EXPECT_FALSE(registry.isBlocked(host));
    EXPECT_TRUE(registry.empty());
}
