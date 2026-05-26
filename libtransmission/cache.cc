// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cerrno>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include <fmt/format.h>

#include "libtransmission/transmission.h"

#include "libtransmission/cache.h"
#include "libtransmission/inout.h"
#include "libtransmission/log.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrents.h"
#include "libtransmission/tr-assert.h"

Cache::Key Cache::make_key(tr_torrent const& tor, tr_block_info::Location const loc) noexcept
{
    return std::make_pair(tor.id(), loc.block);
}

int Cache::set_limit(Memory const max_size)
{
    max_blocks_ = get_max_blocks(max_size);
    tr_logAddDebug(fmt::format("Maximum cache size set to {} ({} blocks)", max_size.to_string(), max_blocks_));

    return trim();
}

Cache::Cache(tr_torrents const& torrents, Memory const max_size)
    : torrents_{ torrents }
    , max_blocks_{ get_max_blocks(max_size) }
{
}

int Cache::write_block(tr_torrent_id_t const tor_id, tr_block_index_t const block, std::unique_ptr<BlockData> writeme)
{
    if (max_blocks_ == 0U)
    {
        {
            auto const lock = std::scoped_lock{ blocks_mutex_ };
            TR_ASSERT(std::empty(blocks_));
        }

        auto* const tor = torrents_.get(tor_id);
        return tor == nullptr ? EINVAL : tr_ioWrite(*tor, tor->block_loc(block), std::size(*writeme), std::data(*writeme));
    }

    auto const lock = std::scoped_lock{ blocks_mutex_ };

    auto const key = Key{ tor_id, block };
    auto iter = std::lower_bound(std::begin(blocks_), std::end(blocks_), key, CompareCacheBlockByKey);
    if (iter == std::end(blocks_) || iter->key != key)
    {
        iter = blocks_.emplace(iter);
        iter->key = key;
    }

    iter->buf = std::move(writeme);

    ++cache_writes_;
    cache_write_bytes_ += std::size(*iter->buf);

    return 0;
}

Cache::CIter Cache::get_block(tr_torrent const& tor, tr_block_info::Location const& loc) noexcept
{
    if (auto const [begin, end] = std::equal_range(
            std::begin(blocks_),
            std::end(blocks_),
            make_key(tor, loc),
            CompareCacheBlockByKey);
        begin < end)
    {
        return begin;
    }

    return std::end(blocks_);
}

int Cache::read_block(tr_torrent const& tor, tr_block_info::Location const& loc, size_t len, uint8_t* setme)
{
    {
        auto const lock = std::scoped_lock{ blocks_mutex_ };
        if (auto const iter = get_block(tor, loc); iter != std::end(blocks_))
        {
            std::copy_n(std::begin(*iter->buf), len, setme);
            return {};
        }
    }

    return tr_ioRead(tor, loc, len, setme);
}

int Cache::trim()
{
    return cache_trim();
}

int Cache::cache_trim()
{
    while (true)
    {
        {
            auto const lock = std::scoped_lock{ blocks_mutex_ };

            if (std::size(blocks_) <= max_blocks_)
            {
                return 0;
            }
        }

        if (auto const err = flush_one_biggest(); err != 0)
        {
            return err;
        }
    }
}
