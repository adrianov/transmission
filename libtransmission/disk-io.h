// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#include <cstddef>
#include <cstdint>
#include <condition_variable>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "libtransmission/transmission.h"

#include "libtransmission/background-work-queue.h"
#include "libtransmission/block-info.h"
#include "libtransmission/error.h"

struct tr_session;
struct tr_torrent;

struct tr_io_write_segment
{
    std::string path;
    uint64_t offset = 0U;
    size_t size = 0U;
    size_t data_offset = 0U;
};

[[nodiscard]] bool tr_ioResolveWriteSegments(
    tr_torrent const& tor,
    tr_block_info::Location loc,
    size_t len,
    std::vector<tr_io_write_segment>& segments);

[[nodiscard]] bool tr_ioWriteSegments(
    std::vector<tr_io_write_segment> const& segments,
    std::vector<uint8_t> const& data,
    tr_error& error);

struct tr_disk_write_job
{
    tr_torrent_id_t tor_id = {};
    tr_block_index_t block = {};
    std::vector<uint8_t> data;
    std::vector<tr_io_write_segment> segments;
    std::vector<std::pair<tr_torrent_id_t, tr_block_index_t>> blocks_to_release;
};

class tr_disk_io_queue final : public BackgroundWorkQueue<tr_disk_write_job>
{
public:
    explicit tr_disk_io_queue(tr_session& session);

    void schedule(tr_disk_write_job job);
    void wait_for_torrent(tr_torrent_id_t tor_id);
    void wait_for_all();

private:
    auto process(tr_disk_write_job& job) -> bool override;
    void bump_pending(tr_torrent_id_t tor_id, int delta);

    tr_session& session_;
    std::mutex pending_mutex_;
    std::condition_variable pending_cv_;
    std::vector<size_t> pending_counts_;
};
