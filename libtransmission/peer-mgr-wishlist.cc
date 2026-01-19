// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cstddef>
#include <functional>
#include <vector>

#define LIBTRANSMISSION_PEER_MODULE

#include "libtransmission/transmission.h"

#include "libtransmission/bitfield.h"
#include "libtransmission/tr-macros.h"
#include "libtransmission/peer-mgr-wishlist.h"

class Wishlist::Impl
{
    struct Candidate
    {
        tr_piece_index_t piece;
        tr_piece_index_t file_index;
        tr_block_span_t block_span;
        tr_priority_t priority;

        [[nodiscard]] constexpr auto sort_key() const noexcept
        {
            return std::tuple{ -priority, file_index, piece };
        }

        [[nodiscard]] constexpr bool operator<(Candidate const& that) const noexcept
        {
            return sort_key() < that.sort_key();
        }
    };

public:
    explicit Impl(Mediator& mediator_in);

    [[nodiscard]] std::vector<tr_block_span_t> next(
        size_t n_wanted_blocks,
        std::function<bool(tr_piece_index_t)> const& peer_has_piece);

    [[nodiscard]] std::vector<tr_block_span_t> next(size_t n_wanted_blocks);

private:
    void rebuild_candidates()
    {
        auto const n_pieces = mediator_.piece_count();
        candidates_.clear();
        candidates_.reserve(n_pieces);
        piece_to_idx_.assign(n_pieces, SIZE_MAX);

        for (tr_piece_index_t piece = 0U; piece < n_pieces; ++piece)
        {
            if (mediator_.client_wants_piece(piece) && !mediator_.client_has_piece(piece))
            {
                piece_to_idx_[piece] = candidates_.size();
                candidates_.push_back(
                    {
                        piece,
                        mediator_.file_index_for_piece(piece),
                        mediator_.block_span(piece),
                        mediator_.priority(piece),
                    });
            }
        }

        std::sort(std::begin(candidates_), std::end(candidates_));

        // Update index after sort
        for (size_t i = 0; i < candidates_.size(); ++i)
        {
            piece_to_idx_[candidates_[i].piece] = i;
        }
    }

    // O(1) piece removal
    void remove_piece(tr_piece_index_t const piece)
    {
        if (piece >= piece_to_idx_.size())
        {
            return;
        }
        auto const idx = piece_to_idx_[piece];
        if (idx == SIZE_MAX || idx >= candidates_.size())
        {
            return;
        }

        piece_to_idx_[piece] = SIZE_MAX;

        // Swap with last for O(1) removal
        if (idx != candidates_.size() - 1)
        {
            piece_to_idx_[candidates_.back().piece] = idx;
            candidates_[idx] = candidates_.back();
        }
        candidates_.pop_back();
    }

    void recalculate_priority()
    {
        for (auto& c : candidates_)
        {
            c.priority = mediator_.priority(c.piece);
        }
        std::sort(std::begin(candidates_), std::end(candidates_));

        for (size_t i = 0; i < candidates_.size(); ++i)
        {
            piece_to_idx_[candidates_[i].piece] = i;
        }
    }

    std::vector<Candidate> candidates_;
    std::vector<size_t> piece_to_idx_; // O(1) piece -> candidate index
    tr_bitfield requested_;
    std::array<libtransmission::ObserverTag, 10U> const tags_;
    Mediator& mediator_;
};

Wishlist::Impl::Impl(Mediator& mediator_in)
    : requested_{ mediator_in.piece_count() > 0 ? mediator_in.block_span(mediator_in.piece_count() - 1).end : 0 }
    , tags_{ {
          mediator_in.observe_files_wanted_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, bool)
                                                   { rebuild_candidates(); }),
          mediator_in.observe_peer_disconnect([this](tr_torrent*, tr_bitfield const&, tr_bitfield const& requests)
                                              { requested_.unset_from(requests); }), // O(n/8) word operations
          mediator_in.observe_got_bad_piece([](tr_torrent*, tr_piece_index_t) {}),
          mediator_in.observe_got_block([this](tr_torrent*, tr_block_index_t b) { requested_.unset(b); }),
          mediator_in.observe_got_choke([](tr_torrent*, tr_bitfield const&) {}),
          mediator_in.observe_got_reject([this](tr_torrent*, tr_peer*, tr_block_index_t b) { requested_.unset(b); }),
          mediator_in.observe_piece_completed([this](tr_torrent*, tr_piece_index_t p) { remove_piece(p); }),
          mediator_in.observe_priority_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, tr_priority_t)
                                               { recalculate_priority(); }),
          mediator_in.observe_sent_cancel([this](tr_torrent*, tr_peer*, tr_block_index_t b) { requested_.unset(b); }),
          mediator_in.observe_sent_request([this](tr_torrent*, tr_peer*, tr_block_span_t bs)
                                           { requested_.set_span(bs.begin, bs.end); }),
      } }
    , mediator_{ mediator_in }
{
    rebuild_candidates();
}

std::vector<tr_block_span_t> Wishlist::Impl::next(size_t const n_wanted_blocks)
{
    if (n_wanted_blocks == 0U || candidates_.empty())
    {
        return {};
    }

    auto spans = std::vector<tr_block_span_t>{};
    spans.reserve(n_wanted_blocks);
    size_t count = 0;

    auto const& have = mediator_.blocks();

    // First pass: unrequested blocks
    for (auto const& c : candidates_)
    {
        for (auto block = c.block_span.begin; block < c.block_span.end && count < n_wanted_blocks;)
        {
            block = requested_.find_first_unset(block, c.block_span.end);
            if (block >= c.block_span.end)
            {
                break;
            }

            if (have.test(block))
            {
                ++block;
                continue;
            }

            auto span_begin = block++;

            while (block < c.block_span.end && count + (block - span_begin) < n_wanted_blocks && !requested_.test(block) &&
                   !have.test(block))
            {
                ++block;
            }

            spans.push_back({ span_begin, block });
            count += block - span_begin;
        }

        if (count >= n_wanted_blocks)
        {
            break;
        }
    }

    // Second pass: endgame - any missing block
    if (count < n_wanted_blocks)
    {
        for (auto const& c : candidates_)
        {
            for (auto block = c.block_span.begin; block < c.block_span.end && count < n_wanted_blocks;)
            {
                block = have.find_first_unset(block, c.block_span.end);
                if (block >= c.block_span.end)
                {
                    break;
                }

                auto span_begin = block++;

                while (block < c.block_span.end && count + (block - span_begin) < n_wanted_blocks && !have.test(block))
                {
                    ++block;
                }

                spans.push_back({ span_begin, block });
                count += block - span_begin;
            }

            if (count >= n_wanted_blocks)
            {
                break;
            }
        }
    }

    return spans;
}

std::vector<tr_block_span_t> Wishlist::Impl::next(
    size_t const n_wanted_blocks,
    std::function<bool(tr_piece_index_t)> const& peer_has_piece)
{
    if (n_wanted_blocks == 0U || candidates_.empty())
    {
        return {};
    }

    auto spans = std::vector<tr_block_span_t>{};
    spans.reserve(n_wanted_blocks);
    size_t count = 0;

    auto const& have = mediator_.blocks();

    // First pass: unrequested blocks
    for (auto const& c : candidates_)
    {
        if (!peer_has_piece(c.piece))
        {
            continue;
        }

        for (auto block = c.block_span.begin; block < c.block_span.end && count < n_wanted_blocks;)
        {
            block = requested_.find_first_unset(block, c.block_span.end);
            if (block >= c.block_span.end)
            {
                break;
            }

            if (have.test(block))
            {
                ++block;
                continue;
            }

            auto span_begin = block++;

            while (block < c.block_span.end && count + (block - span_begin) < n_wanted_blocks && !requested_.test(block) &&
                   !have.test(block))
            {
                ++block;
            }

            spans.push_back({ span_begin, block });
            count += block - span_begin;
        }

        if (count >= n_wanted_blocks)
        {
            break;
        }
    }

    // Second pass: endgame
    if (count < n_wanted_blocks)
    {
        for (auto const& c : candidates_)
        {
            if (!peer_has_piece(c.piece))
            {
                continue;
            }

            for (auto block = c.block_span.begin; block < c.block_span.end && count < n_wanted_blocks;)
            {
                block = have.find_first_unset(block, c.block_span.end);
                if (block >= c.block_span.end)
                {
                    break;
                }

                auto span_begin = block++;

                while (block < c.block_span.end && count + (block - span_begin) < n_wanted_blocks && !have.test(block))
                {
                    ++block;
                }

                spans.push_back({ span_begin, block });
                count += block - span_begin;
            }

            if (count >= n_wanted_blocks)
            {
                break;
            }
        }
    }

    return spans;
}

// ---

Wishlist::Wishlist(Mediator& mediator_in)
    : impl_{ std::make_unique<Impl>(mediator_in) }
{
}

Wishlist::~Wishlist() = default;

std::vector<tr_block_span_t> Wishlist::next(
    size_t const n_wanted_blocks,
    std::function<bool(tr_piece_index_t)> const& peer_has_piece)
{
    return impl_->next(n_wanted_blocks, peer_has_piece);
}

std::vector<tr_block_span_t> Wishlist::next(size_t const n_wanted_blocks)
{
    return impl_->next(n_wanted_blocks);
}
