// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cerrno>

#include "libtransmission/transmission.h"

#include "libtransmission/disk-io.h"
#include "libtransmission/error.h"
#include "libtransmission/file.h"
#include "libtransmission/session.h"
#include "libtransmission/torrent.h"
#include "libtransmission/tr-assert.h"

namespace
{

bool write_entire_buf(tr_sys_file_t const fd, uint64_t file_offset, uint8_t const* buf, uint64_t buflen, tr_error& error)
{
    while (buflen > 0U)
    {
        auto n_written = uint64_t{};
        if (!tr_sys_file_write_at(fd, buf, buflen, file_offset, &n_written, &error))
        {
            return false;
        }

        buf += n_written;
        buflen -= n_written;
        file_offset += n_written;
    }

    return true;
}

} // namespace

bool tr_ioResolveWriteSegments(
    tr_torrent const& tor,
    tr_block_info::Location const loc,
    size_t len,
    std::vector<tr_io_write_segment>& segments)
{
    if (loc.piece >= tor.piece_count())
    {
        return false;
    }

    auto [file_index, file_offset] = tor.file_offset(loc);
    auto data_offset = size_t{ 0U };

    while (len > 0U && file_index < tor.file_count())
    {
        auto const bytes_this_pass = std::min(len, size_t(tor.file_size(file_index) - file_offset));
        auto const found = tor.find_file(file_index);
        if (!found)
        {
            return false;
        }

        segments.push_back(
            tr_io_write_segment{ std::string{ found->filename() }, file_offset, bytes_this_pass, data_offset });

        data_offset += bytes_this_pass;
        len -= bytes_this_pass;
        ++file_index;
        file_offset = 0U;
    }

    return len == 0U;
}

bool tr_ioWriteSegments(
    std::vector<tr_io_write_segment> const& segments,
    std::vector<uint8_t> const& data,
    tr_error& error)
{
    for (auto const& seg : segments)
    {
        auto const fd = tr_sys_file_open(seg.path.c_str(), TR_SYS_FILE_READ | TR_SYS_FILE_WRITE, 0, &error);
        if (fd == TR_BAD_SYS_FILE)
        {
            return false;
        }

        if (!write_entire_buf(fd, seg.offset, std::data(data) + seg.data_offset, seg.size, error))
        {
            tr_sys_file_close(fd);
            return false;
        }

        tr_sys_file_close(fd);
    }

    return true;
}

tr_disk_io_queue::tr_disk_io_queue(tr_session& session)
    : session_{ session }
{
}

void tr_disk_io_queue::schedule(tr_disk_write_job job)
{
    bump_pending(job.tor_id, 1);
    BackgroundWorkQueue::schedule(std::move(job));
}

void tr_disk_io_queue::wait_for_torrent(tr_torrent_id_t const tor_id)
{
    auto lock = std::unique_lock{ pending_mutex_ };
    pending_cv_.wait(lock, [this, tor_id]()
                     {
                         auto const id = static_cast<size_t>(tor_id);
                         return id >= pending_counts_.size() || pending_counts_[id] == 0U;
                     });
}

void tr_disk_io_queue::wait_for_all()
{
    auto lock = std::unique_lock{ pending_mutex_ };
    pending_cv_.wait(lock, [this]()
                     {
                         return std::all_of(std::begin(pending_counts_), std::end(pending_counts_), [](size_t n) { return n == 0U; });
                     });
}

void tr_disk_io_queue::bump_pending(tr_torrent_id_t const tor_id, int const delta)
{
    auto const lock = std::scoped_lock{ pending_mutex_ };
    auto const id = static_cast<size_t>(tor_id);
    if (pending_counts_.size() <= id)
    {
        pending_counts_.resize(id + 1U);
    }

    if (delta > 0)
    {
        pending_counts_[id] += static_cast<size_t>(delta);
    }
    else if (pending_counts_[id] > 0U)
    {
        --pending_counts_[id];
    }

    pending_cv_.notify_all();
}

auto tr_disk_io_queue::process(tr_disk_write_job& job) -> bool
{
    auto error = tr_error{};
    auto const err = tr_ioWriteSegments(job.segments, job.data, error) ? 0 : error.code();

    session_.cache->release_flushed_blocks(job.blocks_to_release);
    bump_pending(job.tor_id, -1);

    if (err != 0)
    {
        session_.run_in_session_thread(
            [this, job, err]()
            {
                if (auto* const tor = session_.torrents().get(job.tor_id);
                    tor != nullptr && tor->error().error_type() != TR_STAT_LOCAL_ERROR)
                {
                    auto write_error = tr_error{};
                    write_error.set(err, "disk write failed");
                    tor->error().set_local_error(write_error.message());
                    tr_torrentStop(tor);
                }
            });
    }

    return true;
}
