// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cerrno>
#include <iterator>
#include <mutex>
#include <numeric>
#include <utility>
#include <vector>

#include "libtransmission/transmission.h"

#include "libtransmission/cache.h"
#include "libtransmission/inout.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrents.h"
#include "libtransmission/tr-assert.h"

Cache::CIter Cache::find_span_end(CIter const& span_begin, CIter const& end) noexcept
{
    static constexpr auto NotAdjacent = [](CacheBlock const& block1, CacheBlock const& block2)
    {
        return block1.key.first != block2.key.first || block1.key.second + 1 != block2.key.second;
    };
    auto const span_end = std::adjacent_find(span_begin, end, NotAdjacent);
    return span_end == end ? end : std::next(span_end);
}

std::pair<Cache::CIter, Cache::CIter> Cache::find_biggest_span(CIter const& begin, CIter const& end) noexcept
{
    auto biggest_begin = begin;
    auto biggest_end = begin;
    auto biggest_len = std::distance(biggest_begin, biggest_end);

    for (auto span_begin = begin; span_begin < end;)
    {
        auto span_end = find_span_end(span_begin, end);

        if (auto const len = std::distance(span_begin, span_end); len > biggest_len)
        {
            biggest_begin = span_begin;
            biggest_end = span_end;
            biggest_len = len;
        }

        span_begin = span_end;
    }

    return { biggest_begin, biggest_end };
}

Cache::ContiguousWrite Cache::make_contiguous_write(CIter const& begin, CIter const& end)
{
    auto write = ContiguousWrite{};
    write.first_key = begin->key;
    write.last_key = std::prev(end)->key;
    write.tor_id = begin->key.first;
    write.block = begin->key.second;

    if (end - begin == 1)
    {
        write.buf.assign(std::begin(*begin->buf), std::end(*begin->buf));
    }
    else
    {
        auto const buflen = std::accumulate(
            begin,
            end,
            size_t{},
            [](size_t sum, auto const& block) { return sum + std::size(*block.buf); });
        write.buf.resize(buflen);
        auto* walk = std::data(write.buf);
        for (auto iter = begin; iter != end; ++iter)
        {
            TR_ASSERT(begin->key.first == iter->key.first);
            TR_ASSERT(begin->key.second + std::distance(begin, iter) == iter->key.second);
            walk = std::copy_n(std::data(*iter->buf), std::size(*iter->buf), walk);
        }
        TR_ASSERT(std::data(write.buf) + std::size(write.buf) == walk);
    }

    return write;
}

std::vector<Cache::ContiguousWrite> Cache::make_span_writes(CIter const& begin, CIter const& end)
{
    auto writes = std::vector<ContiguousWrite>{};

    for (auto span_begin = begin; span_begin < end;)
    {
        auto const span_end = find_span_end(span_begin, end);
        writes.push_back(make_contiguous_write(span_begin, span_end));
        span_begin = span_end;
    }

    return writes;
}

int Cache::execute_write(ContiguousWrite const& write)
{
    auto* const tor = torrents_.get(write.tor_id);
    if (tor == nullptr)
    {
        return EINVAL;
    }

    auto const loc = tor->block_loc(write.block);
    return tr_ioWrite(*tor, loc, std::size(write.buf), std::data(write.buf));
}

void Cache::erase_written_span_locked(ContiguousWrite const& write)
{
    auto const begin = std::lower_bound(std::begin(blocks_), std::end(blocks_), write.first_key, CompareCacheBlockByKey);
    auto const end = std::lower_bound(
        std::begin(blocks_),
        std::end(blocks_),
        std::make_pair(write.last_key.first, write.last_key.second + 1),
        CompareCacheBlockByKey);
    blocks_.erase(begin, end);
}

int Cache::flush_writes(std::vector<ContiguousWrite> writes)
{
    for (auto const& write : writes)
    {
        if (auto const err = execute_write(write); err != 0)
        {
            return err;
        }

        auto const lock = std::scoped_lock{ blocks_mutex_ };
        erase_written_span_locked(write);
        ++disk_writes_;
        disk_write_bytes_ += std::size(write.buf);
    }

    return 0;
}

int Cache::flush_one_biggest()
{
    auto writes = std::vector<ContiguousWrite>{};

    {
        auto const lock = std::scoped_lock{ blocks_mutex_ };
        auto const [begin, end] = find_biggest_span(std::begin(blocks_), std::end(blocks_));

        if (begin == end)
        {
            return 0;
        }

        writes.push_back(make_contiguous_write(begin, end));
    }

    return flush_writes(std::move(writes));
}

int Cache::flush_file(tr_torrent const& tor, tr_file_index_t const file)
{
    auto const tor_id = tor.id();
    auto const [block_begin, block_end] = tor.block_span_for_file(file);

    auto writes = std::vector<ContiguousWrite>{};

    {
        auto const lock = std::scoped_lock{ blocks_mutex_ };
        writes = make_span_writes(
            std::lower_bound(
                std::begin(blocks_),
                std::end(blocks_),
                std::make_pair(tor_id, block_begin),
                CompareCacheBlockByKey),
            std::lower_bound(
                std::begin(blocks_),
                std::end(blocks_),
                std::make_pair(tor_id, block_end),
                CompareCacheBlockByKey));
    }

    return flush_writes(std::move(writes));
}

int Cache::flush_torrent(tr_torrent_id_t const tor_id)
{
    auto writes = std::vector<ContiguousWrite>{};

    {
        auto const lock = std::scoped_lock{ blocks_mutex_ };
        writes = make_span_writes(
            std::lower_bound(std::begin(blocks_), std::end(blocks_), std::make_pair(tor_id, 0), CompareCacheBlockByKey),
            std::lower_bound(
                std::begin(blocks_),
                std::end(blocks_),
                std::make_pair(tor_id + 1, 0),
                CompareCacheBlockByKey));
    }

    return flush_writes(std::move(writes));
}
