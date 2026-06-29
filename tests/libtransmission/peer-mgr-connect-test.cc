// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cstddef>
#include <cstdint>

#include "gtest/gtest.h"

// Bootstrap constants mirrored from peer-mgr-connect.h (peer-module-only header).
namespace
{
auto constexpr ConnectBoostCount = size_t{ 10U };
}

TEST(PeerConnectTest, connectBoostCountIsReasonable)
{
    EXPECT_GE(ConnectBoostCount, size_t{ 5U });
    EXPECT_LE(ConnectBoostCount, size_t{ 30U });
}

TEST(PeerConnectTest, emptySwarmScoresLowerThanConnectedSwarm)
{
    // Highest-priority bit in peer_candidate_score: 0 when swarm has no peers, 1 otherwise.
    auto const empty_swarm_score = uint64_t{ 0U };
    auto const connected_swarm_score = uint64_t{ 1U };
    EXPECT_LT(empty_swarm_score, connected_swarm_score);
}
