// This file copyright Transmission authors and contributors.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <array>
#include <cstdint>

#include <libtransmission/transmission.h>

#include <libtransmission/error.h>
#include <libtransmission/file.h>
#include <libtransmission/inout.h>
#include <libtransmission/open-files.h>
#include <libtransmission/torrent.h>

#include "gtest/gtest.h"
#include "test-fixtures.h"

using InoutTest = libtransmission::test::SessionTest;

namespace
{

[[nodiscard]] uint64_t file_byte_offset(tr_torrent const* tor, tr_file_index_t file_index)
{
    auto offset = uint64_t{};
    for (tr_file_index_t i = 0; i < file_index; ++i)
    {
        offset += tor->file_size(i);
    }
    return offset;
}

} // namespace

TEST_F(InoutTest, finishedFileReadReopensReadOnly)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::Complete);
    auto constexpr FileIndex = tr_file_index_t{ 1 }; // 4096-byte file
    ASSERT_TRUE(tor->has_file(FileIndex));

    auto const found = tor->find_file(FileIndex);
    ASSERT_TRUE(found.has_value());

    // Leftover write handle from downloading.
    auto fd = session_->openFiles().get(
        tor->id(),
        FileIndex,
        true,
        found->filename(),
        tr_open_files::Preallocation::None,
        tor->file_size(FileIndex));
    ASSERT_TRUE(fd.has_value());
    EXPECT_TRUE(session_->openFiles().get(tor->id(), FileIndex, true));

    auto buf = std::array<uint8_t, 64>{};
    auto const loc = tor->byte_loc(file_byte_offset(tor, FileIndex));
    EXPECT_EQ(0, tr_ioRead(*tor, loc, std::size(buf), std::data(buf)));
    EXPECT_FALSE(session_->openFiles().get(tor->id(), FileIndex, true));

    fd = session_->openFiles().get(tor->id(), FileIndex, false);
    ASSERT_TRUE(fd.has_value());
    auto error = tr_error{};
    EXPECT_FALSE(tr_sys_file_write(*fd, "x", 1, nullptr, &error));
    EXPECT_TRUE(error);
}

TEST_F(InoutTest, finishedFileWriteReleasesWriteHandle)
{
    auto* const tor = zeroTorrentInit(ZeroTorrentState::Complete);
    auto constexpr FileIndex = tr_file_index_t{ 2 }; // 512-byte file
    ASSERT_TRUE(tor->has_file(FileIndex));

    auto buf = std::array<uint8_t, 64>{};
    auto const loc = tor->byte_loc(file_byte_offset(tor, FileIndex));
    EXPECT_EQ(0, tr_ioWrite(*tor, loc, std::size(buf), std::data(buf)));
    EXPECT_FALSE(session_->openFiles().get(tor->id(), FileIndex, true));
}
