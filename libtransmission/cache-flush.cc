// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cerrno>
#include <iterator>
#include <memory>
#include <mutex>
#include <numeric>
#include <utility>
#include <vector>

#include "libtransmission/transmission.h"

#include "libtransmission/cache.h"
#include "libtransmission/disk-io.h"
#include "libtransmission/session.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrents.h"
#include "libtransmission/tr-assert.h"

Cache::CIter Cache::find_span_end(CIter const& span_begin, CIter const& end) noexcept
{
    static constexpr auto NotAdjacent = [](CacheBlock const& block1, CacheBlock const& block2)
    {
        return block1.key.first != block2.key.first || block1.key.second + 1 != block2.key.second || block2.flushing;
    };
    auto const span_end = std::adjacent_find(span_begin, end, NotAdjacent);
    return span_end == end ? end : std::next(span_end);
}

std::pair<Cache::CIter, Cache::CIter> Cache::find_biggest_non_flushing_span(CIter const& begin, CIter const& end) noexcept
{
    auto biggest_begin = end;
    auto biggest_end = end;
    auto biggest_len = std::ptrdiff_t{ 0 };

    for (auto span_begin = begin; span_begin < end; span_begin = find_span_end(span_begin, end))
    {
        if (span_begin->flushing)
        {
            continue;
        }

        auto const span_end = find_span_end(span_begin, end);
        if (auto const len = std::distance(span_begin, span_end); len > biggest_len)
        {
            biggest_begin = span_begin;
            biggest_end = span_end;
            biggest_len = len;
        }
    }

    return { biggest_begin, biggest_end };
}

int Cache::prepare_flush_span(CIter const& begin, CIter const& end, tr_disk_write_job& out_job, tr_session*& out_session)
{
    if (begin == end)
    {
        return 0;
    }

    auto const* out = std::data(*begin->buf);
    auto outlen = std::size(*begin->buf);
    auto buf = std::vector<uint8_t>{};

    if (end - begin > 1)
    {
        auto const buflen = std::accumulate(
            begin,
            end,
            size_t{},
            [](size_t sum, auto const& block) { return sum + std::size(*block.buf); });
        buf.resize(buflen);
        auto* walk = std::data(buf);
        for (auto iter = begin; iter != end; ++iter)
        {
            TR_ASSERT(begin->key.first == iter->key.first);
            TR_ASSERT(begin->key.second + std::distance(begin, iter) == iter->key.second);
            walk = std::copy_n(std::data(*iter->buf), std::size(*iter->buf), walk);
        }
        TR_ASSERT(std::data(buf) + std::size(buf) == walk);
        out = std::data(buf);
        outlen = std::size(buf);
    }

    auto const& [torrent_id, block] = begin->key;
    auto* const tor = torrents_.get(torrent_id);
    if (tor == nullptr)
    {
        return EINVAL;
    }

    out_job = tr_disk_write_job{};
    out_job.tor_id = torrent_id;
    out_job.block = block;
    out_job.data.assign(out, out + outlen);

    auto const loc = tor->block_loc(block);
    if (!tr_ioResolveWriteSegments(*tor, loc, outlen, out_job.segments))
    {
        return EINVAL;
    }

    out_job.blocks_to_release.reserve(static_cast<size_t>(end - begin));
    for (auto iter = begin; iter != end; ++iter)
    {
        const_cast<CacheBlock&>(*iter).flushing = true;
        out_job.blocks_to_release.push_back(iter->key);
    }

    out_session = tor->session;

    ++disk_writes_;
    disk_write_bytes_ += outlen;
    return 0;
}

int Cache::flush_biggest_locked(tr_session*& out_session, tr_disk_write_job& out_job)
{
    auto const [begin, end] = find_biggest_non_flushing_span(std::begin(blocks_), std::end(blocks_));

    if (begin == end)
    {
        return 0;
    }

    return prepare_flush_span(begin, end, out_job, out_session);
}

static void schedule_jobs(std::vector<tr_disk_write_job>& jobs, std::vector<tr_session*>& sessions)
{
    TR_ASSERT(std::size(jobs) == std::size(sessions));

    for (size_t i = 0; i < std::size(jobs); ++i)
    {
        if (sessions[i] != nullptr)
        {
            sessions[i]->disk_io().schedule(std::move(jobs[i]));
        }
    }
}

int Cache::flush_file(tr_torrent const& tor, tr_file_index_t const file)
{
    auto const tor_id = tor.id();
    auto const [block_begin, block_end] = tor.block_span_for_file(file);
    auto jobs = std::vector<tr_disk_write_job>{};
    auto sessions = std::vector<tr_session*>{};
    {
        auto const lock = std::scoped_lock{ blocks_mutex_ };
        auto const span_end_bound = std::lower_bound(
            std::begin(blocks_),
            std::end(blocks_),
            std::make_pair(tor_id, block_end),
            CompareCacheBlockByKey);

        for (CIter span_begin = std::lower_bound(
                 std::begin(blocks_),
                 std::end(blocks_),
                 std::make_pair(tor_id, block_begin),
                 CompareCacheBlockByKey);
             span_begin < span_end_bound;)
        {
            auto const span_end = find_span_end(span_begin, span_end_bound);

            auto job = tr_disk_write_job{};
            auto* session = static_cast<tr_session*>(nullptr);
            if (auto const err = prepare_flush_span(span_begin, span_end, job, session); err != 0)
            {
                return err;
            }

            jobs.push_back(std::move(job));
            sessions.push_back(session);
            span_begin = span_end;
        }
    }

    schedule_jobs(jobs, sessions);
    tor.session->disk_io().wait_for_torrent(tor_id);
    return 0;
}

int Cache::flush_torrent(tr_torrent_id_t const tor_id)
{
    auto jobs = std::vector<tr_disk_write_job>{};
    auto sessions = std::vector<tr_session*>{};
    tr_session* wait_session = nullptr;

    {
        auto const lock = std::scoped_lock{ blocks_mutex_ };
        auto const span_end_bound = std::lower_bound(
            std::begin(blocks_),
            std::end(blocks_),
            std::make_pair(tor_id + 1, 0),
            CompareCacheBlockByKey);

        for (CIter span_begin = std::lower_bound(
                 std::begin(blocks_),
                 std::end(blocks_),
                 std::make_pair(tor_id, 0),
                 CompareCacheBlockByKey);
             span_begin < span_end_bound;)
        {
            auto const span_end = find_span_end(span_begin, span_end_bound);

            auto job = tr_disk_write_job{};
            auto* session = static_cast<tr_session*>(nullptr);
            if (auto const err = prepare_flush_span(span_begin, span_end, job, session); err != 0)
            {
                return err;
            }

            jobs.push_back(std::move(job));
            sessions.push_back(session);
            wait_session = session;
            span_begin = span_end;
        }
    }

    schedule_jobs(jobs, sessions);

    if (wait_session != nullptr)
    {
        wait_session->disk_io().wait_for_torrent(tor_id);
    }

    return 0;
}
