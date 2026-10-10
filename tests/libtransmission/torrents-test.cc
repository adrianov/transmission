// This file Copyright (C) 2022 Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <array>
#include <ctime> // time, size_t, time_t
#include <memory>
#include <set>
#include <string_view>
#include <utility>
#include <vector>

#include <libtransmission/transmission.h>

#include <libtransmission/torrent.h>
#include <libtransmission/torrents.h>
#include <libtransmission/torrent-metainfo.h>
#include <libtransmission/tr-strbuf.h>

#include "test-fixtures.h"

using TorrentsTest = ::libtransmission::test::TransmissionTest;
using namespace std::literals;

TEST_F(TorrentsTest, simpleTests)
{
    auto constexpr* const TorrentFile = LIBTRANSMISSION_TEST_ASSETS_DIR "/Android-x86 8.1 r6 iso.torrent";

    auto owned = std::vector<std::unique_ptr<tr_torrent>>{};

    auto tm = tr_torrent_metainfo{};
    EXPECT_TRUE(tm.parse_torrent_file(TorrentFile));
    owned.emplace_back(std::make_unique<tr_torrent>(std::move(tm)));
    auto* const tor = owned.back().get();

    auto torrents = tr_torrents{};
    EXPECT_TRUE(std::empty(torrents));
    EXPECT_EQ(0U, std::size(torrents));

    auto const id = torrents.add(tor);
    EXPECT_GT(id, 0);
    tor->init_id(id);

    EXPECT_TRUE(std::empty(torrents.removedSince(0)));
    EXPECT_FALSE(std::empty(torrents));
    EXPECT_EQ(1U, std::size(torrents));

    EXPECT_EQ(tor, torrents.get(id));
    EXPECT_EQ(tor, torrents.get(tor->info_hash()));
    EXPECT_EQ(tor, torrents.get(tor->magnet()));

    tm = tr_torrent_metainfo{};
    EXPECT_TRUE(tm.parse_torrent_file(TorrentFile));
    EXPECT_EQ(tor, torrents.get(tm));

    // cleanup
    torrents.remove(tor, time(nullptr));
}

TEST_F(TorrentsTest, rangedLoop)
{
    auto constexpr Filenames = std::array<std::string_view, 4>{ "Android-x86 8.1 r6 iso.torrent"sv,
                                                                "debian-11.2.0-amd64-DVD-1.iso.torrent"sv,
                                                                "ubuntu-18.04.6-desktop-amd64.iso.torrent"sv,
                                                                "ubuntu-20.04.4-desktop-amd64.iso.torrent"sv };

    auto owned = std::vector<std::unique_ptr<tr_torrent>>{};
    auto torrents = tr_torrents{};
    auto torrents_set = std::set<tr_torrent const*>{};

    for (auto const& name : Filenames)
    {
        auto const path = tr_pathbuf{ LIBTRANSMISSION_TEST_ASSETS_DIR, '/', name };
        auto tm = tr_torrent_metainfo{};
        EXPECT_TRUE(tm.parse_torrent_file(path));
        owned.emplace_back(std::make_unique<tr_torrent>(std::move(tm)));

        auto* const tor = owned.back().get();
        tor->init_id(torrents.add(tor));
        EXPECT_EQ(tor, torrents.get(tor->id()));
        torrents_set.insert(tor);
    }

    for (auto* const tor : torrents)
    {
        EXPECT_EQ(1U, torrents_set.erase(tor));
    }
    EXPECT_EQ(0U, std::size(torrents_set));
}

TEST_F(TorrentsTest, removedSince)
{
    auto constexpr Filenames = std::array<std::string_view, 4>{ "Android-x86 8.1 r6 iso.torrent"sv,
                                                                "debian-11.2.0-amd64-DVD-1.iso.torrent"sv,
                                                                "ubuntu-18.04.6-desktop-amd64.iso.torrent"sv,
                                                                "ubuntu-20.04.4-desktop-amd64.iso.torrent"sv };

    auto owned = std::vector<std::unique_ptr<tr_torrent>>{};
    auto torrents = tr_torrents{};
    auto torrents_v = std::vector<tr_torrent const*>{};
    torrents_v.reserve(std::size(Filenames));

    // setup: add the torrents
    for (auto const& name : Filenames)
    {
        auto const path = tr_pathbuf{ LIBTRANSMISSION_TEST_ASSETS_DIR, '/', name };
        auto tm = tr_torrent_metainfo{};
        EXPECT_TRUE(tm.parse_torrent_file(path));
        owned.emplace_back(std::make_unique<tr_torrent>(std::move(tm)));

        auto* const tor = owned.back().get();
        tor->init_id(torrents.add(tor));
        torrents_v.push_back(tor);
    }

    // setup: remove them at the given timestamp
    auto constexpr TimeRemoved = std::array<time_t, 4>{ 100, 200, 200, 300 };
    for (size_t i = 0; i < 4; ++i)
    {
        auto* const tor = torrents_v[i];
        EXPECT_EQ(tor, torrents.get(tor->id()));
        torrents.remove(torrents_v[i], TimeRemoved[i]);
        EXPECT_EQ(nullptr, torrents.get(tor->id()));
    }

    auto remove = std::vector<tr_torrent_id_t>{};
    remove = { torrents_v[3]->id() };
    EXPECT_EQ(remove, torrents.removedSince(300));
    EXPECT_EQ(remove, torrents.removedSince(201));
    remove = { torrents_v[1]->id(), torrents_v[2]->id(), torrents_v[3]->id() };
    EXPECT_EQ(remove, torrents.removedSince(200));
    remove = { torrents_v[0]->id(), torrents_v[1]->id(), torrents_v[2]->id(), torrents_v[3]->id() };
    EXPECT_EQ(remove, torrents.removedSince(50));
}

using TorrentsPieceSpanTest = libtransmission::test::SessionTest;

TEST_F(TorrentsPieceSpanTest, exposesFilePieceSpan)
{
    auto const file_view = tr_torrentFile(zeroTorrentInit(ZeroTorrentState::Complete), 0);
    EXPECT_EQ(file_view.beginPiece, 0);
    EXPECT_EQ(file_view.endPiece, 32);
}

using TorrentsMergeTrackerListTest = libtransmission::test::SessionTest;

TEST_F(TorrentsMergeTrackerListTest, skipsVerifyWhenNoLocalData)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);

    // Nothing on disk matches the torrent files, so the verify queue is skipped.
    EXPECT_FALSE(tor->is_piece_checked(0));
    EXPECT_EQ(TR_STATUS_STOPPED, tor->activity());
    EXPECT_TRUE(tor->has_none());
}

TEST_F(TorrentsMergeTrackerListTest, mergesTrackersFromDuplicateMetainfo)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);

    // setup: a duplicate of the same torrent (same info hash) with an extra tracker
    auto dup = tr_torrent_metainfo{};
    ASSERT_TRUE(dup.parse_torrent_file(tor->torrent_file()));
    EXPECT_EQ(tor->info_hash(), dup.info_hash());
    ASSERT_TRUE(dup.announce_list().add("udp://tracker.example.org:1337/announce"sv));

    // the extra tracker is added; the original one is kept
    EXPECT_EQ(1U, tr_torrentMergeTrackersFromMetainfo(tor, &dup));
    EXPECT_EQ("http://www.example.com/announce\n\nudp://tracker.example.org:1337/announce\n", tr_torrentGetTrackerList(tor));
}

TEST_F(TorrentsMergeTrackerListTest, mergeIsIdempotent)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);

    auto dup = tr_torrent_metainfo{};
    ASSERT_TRUE(dup.parse_torrent_file(tor->torrent_file()));
    ASSERT_TRUE(dup.announce_list().add("udp://tracker.example.org:1337/announce"sv));

    EXPECT_EQ(1U, tr_torrentMergeTrackersFromMetainfo(tor, &dup));
    EXPECT_EQ(0U, tr_torrentMergeTrackersFromMetainfo(tor, &dup));
}

TEST_F(TorrentsMergeTrackerListTest, mergeIgnoresTrackersAlreadyPresent)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);

    // the duplicate has exactly the same trackers as the torrent
    auto same = tr_torrent_metainfo{};
    ASSERT_TRUE(same.parse_torrent_file(tor->torrent_file()));

    EXPECT_EQ(0U, tr_torrentMergeTrackersFromMetainfo(tor, &same));
    EXPECT_EQ("http://www.example.com/announce\n", tr_torrentGetTrackerList(tor));
}

TEST_F(TorrentsMergeTrackerListTest, mergeRollsBackWhenPersistingFails)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);

    auto dup = tr_torrent_metainfo{};
    ASSERT_TRUE(dup.parse_torrent_file(tor->torrent_file()));
    ASSERT_TRUE(dup.announce_list().add("udp://tracker.example.org:1337/announce"sv));

    // corrupt the backing file so persisting the merged list fails
    createFileWithContents(tor->torrent_file(), "not a torrent"sv);

    // the merge reports failure and restores the previous list, so
    // reopening the same file can retry the merge later
    EXPECT_EQ(0U, tr_torrentMergeTrackersFromMetainfo(tor, &dup));
    EXPECT_EQ("http://www.example.com/announce\n", tr_torrentGetTrackerList(tor));
}

using TorrentsRemoveTrackerListTest = libtransmission::test::SessionTest;

TEST_F(TorrentsRemoveTrackerListTest, removesTracker)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);
    ASSERT_TRUE(tor->set_announce_list("http://www.example.com/announce\nudp://tracker.example.org:1337/announce\n"sv));

    EXPECT_EQ(1U, tor->remove_announce("http://www.example.com/announce"sv));
    EXPECT_EQ("udp://tracker.example.org:1337/announce\n", tr_torrentGetTrackerList(tor));

    // the change persists to the torrent file
    auto reloaded = tr_torrent_metainfo{};
    ASSERT_TRUE(reloaded.parse_torrent_file(tor->torrent_file()));
    EXPECT_EQ(1U, std::size(reloaded.announce_list()));
    EXPECT_EQ("udp://tracker.example.org:1337/announce"sv, reloaded.announce_list().at(0).announce.sv());
}

TEST_F(TorrentsRemoveTrackerListTest, keepsLastTracker)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);

    // refuse to remove the torrent's only tracker
    EXPECT_EQ(0U, tor->remove_announce("http://www.example.com/announce"sv));
    EXPECT_EQ("http://www.example.com/announce\n", tr_torrentGetTrackerList(tor));
}

TEST_F(TorrentsRemoveTrackerListTest, ignoresUnknownTracker)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);
    ASSERT_TRUE(tor->set_announce_list("http://www.example.com/announce\nudp://tracker.example.org:1337/announce\n"sv));

    EXPECT_EQ(0U, tor->remove_announce("https://www.not-example.com/announce"sv));
    EXPECT_EQ("http://www.example.com/announce\nudp://tracker.example.org:1337/announce\n", tr_torrentGetTrackerList(tor));
}

TEST_F(TorrentsRemoveTrackerListTest, rollsBackWhenPersistingFails)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::NoFiles);
    ASSERT_NE(nullptr, tor);
    ASSERT_TRUE(tor->set_announce_list("http://www.example.com/announce\nudp://tracker.example.org:1337/announce\n"sv));

    // corrupt the backing file so persisting the removal fails
    createFileWithContents(tor->torrent_file(), "not a torrent"sv);

    // the removal reports failure and restores the previous list, so
    // reopening the same file can retry the removal later
    EXPECT_EQ(0U, tor->remove_announce("http://www.example.com/announce"sv));
    EXPECT_EQ("http://www.example.com/announce\nudp://tracker.example.org:1337/announce\n", tr_torrentGetTrackerList(tor));
}
