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

int Cache::write_contiguous(CIter const& begin, CIter const& end)
{
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

    auto const loc = tor->block_loc(block);
    if (auto const err = tr_ioWrite(*tor, loc, outlen, out); err != 0)
    {
        return err;
    }

    ++disk_writes_;
    disk_write_bytes_ += outlen;
    return 0;
}

int Cache::flush_spans_locked(CIter const& begin, CIter const& end)
{
    for (auto span_begin = begin; span_begin < end;)
    {
        auto const span_end = find_span_end(span_begin, end);

        if (auto const err = write_contiguous(span_begin, span_end); err != 0)
        {
            return err;
        }

        span_begin = span_end;
    }

    blocks_.erase(begin, end);
    return 0;
}

int Cache::flush_biggest_locked()
{
    auto const [begin, end] = find_biggest_span(std::begin(blocks_), std::end(blocks_));

    if (begin == end)
    {
        return 0;
    }

    if (auto const err = write_contiguous(begin, end); err != 0)
    {
        return err;
    }

    blocks_.erase(begin, end);
    return 0;
}

int Cache::flush_file(tr_torrent const& tor, tr_file_index_t const file)
{
    auto const tor_id = tor.id();
    auto const [block_begin, block_end] = tor.block_span_for_file(file);

    auto const lock = std::scoped_lock{ blocks_mutex_ };

    return flush_spans_locked(
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

int Cache::flush_torrent(tr_torrent_id_t const tor_id)
{
    auto const lock = std::scoped_lock{ blocks_mutex_ };

    return flush_spans_locked(
        std::lower_bound(std::begin(blocks_), std::end(blocks_), std::make_pair(tor_id, 0), CompareCacheBlockByKey),
        std::lower_bound(
            std::begin(blocks_),
            std::end(blocks_),
            std::make_pair(tor_id + 1, 0),
            CompareCacheBlockByKey));
}
