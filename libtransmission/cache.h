// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#include <cstddef> // for size_t
#include <cstdint> // for intX_t, uintX_t
#include <memory> // for std::unique_ptr
#include <mutex>
#include <utility> // for std::pair
#include <vector>

#include <small/vector.hpp>

#include "libtransmission/transmission.h"

#include "libtransmission/block-info.h"
#include "libtransmission/values.h"

class tr_torrents;
struct tr_torrent;

class Cache
{
public:
    using BlockData = small::max_size_vector<uint8_t, tr_block_info::BlockSize>;
    using Memory = libtransmission::Values::Memory;

    Cache(tr_torrents const& torrents, Memory max_size);

    int set_limit(Memory max_size);

    // Insert or replace a cached block. Does not trim; callers must invoke trim()
    // after piece bookkeeping (see tr_torrent::on_block_received).
    int write_block(tr_torrent_id_t tor, tr_block_index_t block, std::unique_ptr<BlockData> writeme);

    int read_block(tr_torrent const& tor, tr_block_info::Location const& loc, size_t len, uint8_t* setme);
    int flush_torrent(tr_torrent_id_t tor_id);
    int flush_file(tr_torrent const& tor, tr_file_index_t file);

    // Flush excess cache blocks to disk. Call after write_block when piece
    // bookkeeping is done so trim does not run before check_piece reads cache.
    int trim();

private:
    using Key = std::pair<tr_torrent_id_t, tr_block_index_t>;

    struct CacheBlock
    {
        Key key;
        std::unique_ptr<BlockData> buf;
    };

    using Blocks = std::vector<CacheBlock>;
    using CIter = Blocks::const_iterator;

    struct ContiguousWrite
    {
        tr_torrent_id_t tor_id = {};
        tr_block_index_t block = {};
        Key first_key;
        Key last_key;
        std::vector<uint8_t> buf;
    };

    [[nodiscard]] static Key make_key(tr_torrent const& tor, tr_block_info::Location loc) noexcept;

    [[nodiscard]] static std::pair<CIter, CIter> find_biggest_span(CIter const& begin, CIter const& end) noexcept;

    [[nodiscard]] static CIter find_span_end(CIter const& span_begin, CIter const& end) noexcept;

    // Caller must hold blocks_mutex_. Copies span data and keys only.
    [[nodiscard]] static ContiguousWrite make_contiguous_write(CIter const& begin, CIter const& end);

    // Caller must hold blocks_mutex_.
    [[nodiscard]] static std::vector<ContiguousWrite> make_span_writes(CIter const& begin, CIter const& end);

    [[nodiscard]] int execute_write(ContiguousWrite const& write);

    // Caller must hold blocks_mutex_.
    void erase_written_span_locked(ContiguousWrite const& write);

    // @return any error code from execute_write()
    [[nodiscard]] int flush_one_biggest();

    // @return any error code from execute_write()
    [[nodiscard]] int flush_writes(std::vector<ContiguousWrite> writes);

    // @return any error code from flush_one_biggest()
    [[nodiscard]] int cache_trim();

    [[nodiscard]] static constexpr size_t get_max_blocks(Memory const max_size) noexcept
    {
        return max_size.base_quantity() / tr_block_info::BlockSize;
    }

    [[nodiscard]] CIter get_block(tr_torrent const& tor, tr_block_info::Location const& loc) noexcept;

    tr_torrents const& torrents_;

    Blocks blocks_;
    mutable std::mutex blocks_mutex_;
    size_t max_blocks_ = 0;

    mutable size_t disk_writes_ = 0;
    mutable size_t disk_write_bytes_ = 0;
    mutable size_t cache_writes_ = 0;
    mutable size_t cache_write_bytes_ = 0;

    static constexpr struct
    {
        [[nodiscard]] constexpr bool operator()(Key const& key, CacheBlock const& block) const
        {
            return key < block.key;
        }
        [[nodiscard]] constexpr bool operator()(CacheBlock const& block, Key const& key) const
        {
            return block.key < key;
        }
    } CompareCacheBlockByKey{};
};
