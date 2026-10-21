// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cstdint>

#define LIBTRANSMISSION_PEER_MODULE

#include <libtransmission/transmission.h>

#include <libtransmission/peer-mgr-connect.h>

#include "gtest/gtest.h"

using namespace peer_mgr_connect;

TEST(PeerConnectTest, connectBoostCountIsReasonable)
{
    EXPECT_GE(ConnectBoostCount, size_t{ 5U });
    EXPECT_LE(ConnectBoostCount, size_t{ 30U });
}

// The done bit is the most significant field, so any downloading torrent's peer must be
// preferred over a seeding torrent's peer, even when it loses every lower-priority field.
TEST(PeerConnectTest, downloadingOutranksDone)
{
    auto downloading = CandidateKey{};
    downloading.is_done = 0U;
    downloading.swarm_has_peers = 1U;
    downloading.had_fruitless = 1U;
    downloading.last_attempt_time = 0xFFFFFFFFU;
    downloading.torrent_priority = 2U;
    downloading.not_started_recently = 1U;
    downloading.not_connectable = 1U;
    downloading.is_upload_only = 1U;
    downloading.from_best = 0xFU;
    downloading.salt = 0xFFU;

    auto done = CandidateKey{};
    done.is_done = 1U;

    EXPECT_LT(compose_candidate_score(downloading), compose_candidate_score(done));
}

// Within the same download state, a peer in a swarm with no connections is preferred,
// even when it loses every lower-priority field.
TEST(PeerConnectTest, emptySwarmOutranksConnectedSwarm)
{
    auto empty = CandidateKey{};
    empty.swarm_has_peers = 0U;
    empty.had_fruitless = 1U;
    empty.last_attempt_time = 0xFFFFFFFFU;
    empty.torrent_priority = 2U;
    empty.not_started_recently = 1U;
    empty.not_connectable = 1U;
    empty.is_upload_only = 1U;
    empty.from_best = 0xFU;
    empty.salt = 0xFFU;

    auto connected = CandidateKey{};
    connected.swarm_has_peers = 1U;

    EXPECT_LT(compose_candidate_score(empty), compose_candidate_score(connected));
}

// Salt is the least significant field: it only breaks ties between otherwise-equal keys.
TEST(PeerConnectTest, saltIsLeastSignificant)
{
    auto low_salt = CandidateKey{};
    low_salt.salt = 0U;

    auto high_salt = CandidateKey{};
    high_salt.salt = 0xFFU;

    EXPECT_LT(compose_candidate_score(low_salt), compose_candidate_score(high_salt));

    // A single higher-field difference must outweigh any salt value.
    high_salt.salt = 0U;
    low_salt.salt = 0xFFU;
    low_salt.from_best = 0U;
    high_salt.from_best = 1U;
    EXPECT_LT(compose_candidate_score(low_salt), compose_candidate_score(high_salt));
}
