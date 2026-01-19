// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm> // std::adjacent_find, std::sort
#include <cstddef>
#include <functional>
#include <utility>
#include <vector>

#include <small/set.hpp>
#include <small/vector.hpp>

#define LIBTRANSMISSION_PEER_MODULE

#include "libtransmission/transmission.h"

#include "libtransmission/bitfield.h"
#include "libtransmission/tr-macros.h"
#include "libtransmission/peer-mgr-wishlist.h"

namespace
{
[[nodiscard]] std::vector<tr_block_span_t> make_spans(small::vector<tr_block_index_t> const& blocks)
{
    if (std::empty(blocks))
    {
        return {};
    }

    auto spans = std::vector<tr_block_span_t>{};
    spans.reserve(std::size(blocks));
    for (auto span_begin = std::begin(blocks), end = std::end(blocks); span_begin != end;)
    {
        static auto constexpr NotAdjacent = [](tr_block_index_t const lhs, tr_block_index_t const rhs)
        {
            return lhs + 1U != rhs;
        };

        auto const span_end = std::min(std::adjacent_find(span_begin, end, NotAdjacent), std::prev(end));
        spans.push_back({ *span_begin, *span_end + 1U });

        span_begin = std::next(span_end);
    }

    return spans;
}
} // namespace

class Wishlist::Impl
{
    struct Candidate
    {
        Candidate(tr_piece_index_t piece_in, Mediator const* mediator)
            : piece{ piece_in }
            , file_index{ mediator->file_index_for_piece(piece_in) }
            , block_span{ mediator->block_span(piece_in) }
            , priority{ mediator->priority(piece_in) }
        {
            for (auto block = block_span.begin; block < block_span.end; ++block)
            {
                if (!mediator->client_has_block(block))
                {
                    unrequested.insert(block);
                }
            }
        }

        // Sort key: priority (high first), file (alphabetically), piece number.
        [[nodiscard]] constexpr auto sort_key() const noexcept
        {
            return std::tuple{ -priority, file_index, piece };
        }

        [[nodiscard]] constexpr bool operator<(Candidate const& that) const noexcept
        {
            return sort_key() < that.sort_key();
        }

        [[nodiscard]] constexpr auto block_belongs(tr_block_index_t const block) const noexcept
        {
            return block_span.begin <= block && block < block_span.end;
        }

        tr_piece_index_t piece;
        tr_piece_index_t file_index;
        tr_block_span_t block_span;
        tr_priority_t priority;

        // Blocks not yet requested (sorted descending for efficient removal from end)
        small::set<tr_block_index_t, small::default_inline_storage_v<tr_block_index_t>, std::greater<>> unrequested;
    };

    using CandidateVec = std::vector<Candidate>;

public:
    explicit Impl(Mediator& mediator_in);

    [[nodiscard]] std::vector<tr_block_span_t> next(
        size_t n_wanted_blocks,
        std::function<bool(tr_piece_index_t)> const& peer_has_piece);

private:
    void sort_candidates()
    {
        std::sort(std::begin(candidates_), std::end(candidates_));
    }

    void requested_block_span(tr_block_span_t const block_span)
    {
        for (auto& candidate : candidates_)
        {
            if (candidate.block_span.end <= block_span.begin || candidate.block_span.begin >= block_span.end)
            {
                continue; // No overlap
            }
            for (auto block = block_span.begin; block < block_span.end; ++block)
            {
                candidate.unrequested.erase(block);
            }
        }
    }

    void reset_block(tr_block_index_t block)
    {
        for (auto& candidate : candidates_)
        {
            if (candidate.block_belongs(block) && !mediator_.client_has_block(block))
            {
                candidate.unrequested.insert(block);
            }
        }
    }

    void reset_blocks_bitfield(tr_bitfield const& requests)
    {
        for (auto& candidate : candidates_)
        {
            for (auto block = candidate.block_span.begin; block < candidate.block_span.end; ++block)
            {
                if (requests.test(block) && !mediator_.client_has_block(block))
                {
                    candidate.unrequested.insert(block);
                }
            }
        }
    }

    void client_got_block(tr_block_index_t block)
    {
        for (auto& candidate : candidates_)
        {
            candidate.unrequested.erase(block);
        }
    }

    void got_bad_piece(tr_piece_index_t const piece)
    {
        auto const iter = find_by_piece(piece);
        if (iter == std::end(candidates_))
        {
            return;
        }

        iter->unrequested.clear();
        for (auto block = iter->block_span.begin; block < iter->block_span.end; ++block)
        {
            if (!mediator_.client_has_block(block))
            {
                iter->unrequested.insert(block);
            }
        }
    }

    [[nodiscard]] CandidateVec::iterator find_by_piece(tr_piece_index_t const piece)
    {
        return std::find_if(
            std::begin(candidates_),
            std::end(candidates_),
            [piece](auto const& c) { return c.piece == piece; });
    }

    void candidate_list_upkeep()
    {
        auto const n_pieces = mediator_.piece_count();

        candidates_.clear();
        candidates_.reserve(n_pieces);

        for (tr_piece_index_t piece = 0U; piece < n_pieces; ++piece)
        {
            if (mediator_.client_wants_piece(piece) && !mediator_.client_has_piece(piece))
            {
                candidates_.emplace_back(piece, &mediator_);
            }
        }

        sort_candidates();
    }

    void remove_piece(tr_piece_index_t const piece)
    {
        if (auto iter = find_by_piece(piece); iter != std::end(candidates_))
        {
            candidates_.erase(iter);
        }
    }

    void recalculate_priority()
    {
        for (auto& candidate : candidates_)
        {
            candidate.priority = mediator_.priority(candidate.piece);
        }
        sort_candidates();
    }

    CandidateVec candidates_;
    std::array<libtransmission::ObserverTag, 10U> const tags_;
    Mediator& mediator_;
};

Wishlist::Impl::Impl(Mediator& mediator_in)
    : tags_{ {
          mediator_in.observe_files_wanted_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, bool)
                                                   { candidate_list_upkeep(); }),
          mediator_in.observe_peer_disconnect([this](tr_torrent*, tr_bitfield const&, tr_bitfield const& requests)
                                              { reset_blocks_bitfield(requests); }),
          mediator_in.observe_got_bad_piece([this](tr_torrent*, tr_piece_index_t p) { got_bad_piece(p); }),
          mediator_in.observe_got_block([this](tr_torrent*, tr_block_index_t b) { client_got_block(b); }),
          mediator_in.observe_got_choke([this](tr_torrent*, tr_bitfield const& b) { reset_blocks_bitfield(b); }),
          mediator_in.observe_got_reject([this](tr_torrent*, tr_peer*, tr_block_index_t b) { reset_block(b); }),
          mediator_in.observe_piece_completed([this](tr_torrent*, tr_piece_index_t p) { remove_piece(p); }),
          mediator_in.observe_priority_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, tr_priority_t)
                                               { recalculate_priority(); }),
          mediator_in.observe_sent_cancel([this](tr_torrent*, tr_peer*, tr_block_index_t b) { reset_block(b); }),
          mediator_in.observe_sent_request([this](tr_torrent*, tr_peer*, tr_block_span_t bs) { requested_block_span(bs); }),
      } }
    , mediator_{ mediator_in }
{
    candidate_list_upkeep();
}

std::vector<tr_block_span_t> Wishlist::Impl::next(
    size_t const n_wanted_blocks,
    std::function<bool(tr_piece_index_t)> const& peer_has_piece)
{
    if (n_wanted_blocks == 0U || candidates_.empty())
    {
        return {};
    }

    auto blocks = small::vector<tr_block_index_t>{};
    blocks.reserve(n_wanted_blocks);

    // First pass: request unrequested blocks in priority order
    for (auto const& candidate : candidates_)
    {
        if (std::size(blocks) >= n_wanted_blocks)
        {
            break;
        }
        if (!peer_has_piece(candidate.piece) || candidate.unrequested.empty())
        {
            continue;
        }
        for (auto it = candidate.unrequested.rbegin();
             it != candidate.unrequested.rend() && std::size(blocks) < n_wanted_blocks;
             ++it)
        {
            blocks.push_back(*it);
        }
    }

    // Second pass: if we need more blocks, request any missing block (even if already requested)
    // This handles endgame and stuck requests
    if (std::size(blocks) < n_wanted_blocks)
    {
        for (auto const& candidate : candidates_)
        {
            if (std::size(blocks) >= n_wanted_blocks)
            {
                break;
            }
            if (!peer_has_piece(candidate.piece))
            {
                continue;
            }
            for (auto block = candidate.block_span.begin;
                 block < candidate.block_span.end && std::size(blocks) < n_wanted_blocks;
                 ++block)
            {
                if (!mediator_.client_has_block(block))
                {
                    blocks.push_back(block);
                }
            }
        }
    }

    std::sort(std::begin(blocks), std::end(blocks));
    blocks.erase(std::unique(std::begin(blocks), std::end(blocks)), std::end(blocks));
    return make_spans(blocks);
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
