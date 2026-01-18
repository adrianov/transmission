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
            , raw_block_span{ block_span }
            , priority{ mediator->priority(piece_in) }
        {
            unrequested.reserve(block_span.end - block_span.begin);
            for (auto [begin, i] = block_span; i > begin; --i)
            {
                if (auto const block = i - 1U; !mediator->client_has_block(block))
                {
                    unrequested.insert(block);
                }
            }
        }

        // Sort key: priority (high first), file (alphabetically), piece number.
        // This order is static - only changes when priority changes.
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
        tr_piece_index_t file_index; // alphabetical file index, cached for sorting
        tr_block_span_t block_span;
        tr_block_span_t raw_block_span;

        // Sorted descending so smaller block indices can be taken from end (no move needed)
        small::set<tr_block_index_t, small::default_inline_storage_v<tr_block_index_t>, std::greater<>> unrequested;

        tr_priority_t priority;
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

    // ---

    void requested_block_span(tr_block_span_t const block_span)
    {
        for (auto block = block_span.begin; block < block_span.end;)
        {
            auto it_p = find_by_block(block);
            if (it_p == std::end(candidates_))
            {
                break;
            }

            auto& unreq = it_p->unrequested;

            auto it_b_end = std::end(unreq);
            it_b_end = *std::prev(it_b_end) >= block_span.begin ? it_b_end : unreq.upper_bound(block_span.begin);

            auto it_b_begin = std::begin(unreq);
            it_b_begin = *it_b_begin < block_span.end ? it_b_begin : unreq.upper_bound(block_span.end);

            unreq.erase(it_b_begin, it_b_end);

            block = it_p->block_span.end;
            // No resort needed - sort key doesn't include unrequested count
        }
    }

    void reset_block(tr_block_index_t block)
    {
        if (auto it_p = find_by_block(block); it_p != std::end(candidates_))
        {
            it_p->unrequested.insert(block);
            // No resort needed - sort key doesn't include unrequested count
        }
    }

    void reset_blocks_bitfield(tr_bitfield const& requests)
    {
        for (auto& candidate : candidates_)
        {
            auto const [begin, end] = candidate.block_span;
            if (requests.count(begin, end) == 0U)
            {
                continue;
            }

            for (auto i = end; i > begin; --i)
            {
                if (auto const block = i - 1U; requests.test(block))
                {
                    candidate.unrequested.insert(block);
                }
            }
        }
        // No sort needed - sort key doesn't include unrequested count
    }

    // ---

    void client_got_block(tr_block_index_t block)
    {
        if (auto const iter = find_by_block(block); iter != std::end(candidates_))
        {
            iter->unrequested.erase(block);
            // No resort needed - sort key doesn't include unrequested count
        }
    }

    // ---

    void got_bad_piece(tr_piece_index_t const piece)
    {
        // Bad piece is rare - just rebuild the candidate list
        auto const iter = find_by_piece(piece);
        if (iter == std::end(candidates_))
        {
            return;
        }

        // Reset all blocks as unrequested for this piece
        iter->block_span = iter->raw_block_span;
        iter->unrequested.clear();
        for (auto [begin, i] = iter->block_span; i > begin; --i)
        {
            if (!mediator_.client_has_block(i - 1U))
            {
                iter->unrequested.insert(i - 1U);
            }
        }
    }

    // ---

    [[nodiscard]] TR_CONSTEXPR20 CandidateVec::iterator find_by_piece(tr_piece_index_t const piece)
    {
        return std::find_if(
            std::begin(candidates_),
            std::end(candidates_),
            [piece](auto const& c) { return c.piece == piece; });
    }

    [[nodiscard]] TR_CONSTEXPR20 CandidateVec::iterator find_by_block(tr_block_index_t const block)
    {
        return std::find_if(
            std::begin(candidates_),
            std::end(candidates_),
            [block](auto const& c) { return c.block_belongs(block); });
    }

    void candidate_list_upkeep()
    {
        // Rebuild candidate list from scratch - simpler and the sort key is static
        auto const n_pieces = mediator_.piece_count();

        // Collect wanted pieces
        auto new_candidates = CandidateVec{};
        new_candidates.reserve(n_pieces);

        for (tr_piece_index_t piece = 0U; piece < n_pieces; ++piece)
        {
            if (mediator_.client_wants_piece(piece) && !mediator_.client_has_piece(piece))
            {
                new_candidates.emplace_back(piece, &mediator_);
            }
        }

        // Sort once by our static sort key
        std::sort(std::begin(new_candidates), std::end(new_candidates));

        // Handle block span overlaps between consecutive pieces
        for (size_t i = 1; i < new_candidates.size(); ++i)
        {
            auto& prev = new_candidates[i - 1];
            auto& curr = new_candidates[i];

            if (prev.block_span.end > curr.block_span.begin)
            {
                // Overlapping blocks - assign to earlier piece, remove from later
                for (auto block = curr.block_span.begin; block < prev.block_span.end; ++block)
                {
                    curr.unrequested.erase(block);
                }
                curr.block_span.begin = prev.block_span.end;
            }
        }

        candidates_ = std::move(new_candidates);
    }

    // ---

    void remove_piece(tr_piece_index_t const piece)
    {
        if (auto iter = find_by_piece(piece); iter != std::end(candidates_))
        {
            candidates_.erase(iter);
        }
    }

    // ---

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
          // candidates
          mediator_in.observe_files_wanted_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, bool)
                                                   { candidate_list_upkeep(); }),
          // unrequested
          mediator_in.observe_peer_disconnect([this](tr_torrent*, tr_bitfield const&, tr_bitfield const& requests)
                                              { reset_blocks_bitfield(requests); }),
          // unrequested
          mediator_in.observe_got_bad_piece([this](tr_torrent*, tr_piece_index_t p) { got_bad_piece(p); }),
          // unrequested
          mediator_in.observe_got_block([this](tr_torrent*, tr_block_index_t b) { client_got_block(b); }),
          // unrequested
          mediator_in.observe_got_choke([this](tr_torrent*, tr_bitfield const& b) { reset_blocks_bitfield(b); }),
          // unrequested
          mediator_in.observe_got_reject([this](tr_torrent*, tr_peer*, tr_block_index_t b) { reset_block(b); }),
          // candidates
          mediator_in.observe_piece_completed([this](tr_torrent*, tr_piece_index_t p) { remove_piece(p); }),
          // priority
          mediator_in.observe_priority_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, tr_priority_t)
                                               { recalculate_priority(); }),
          // unrequested
          mediator_in.observe_sent_cancel([this](tr_torrent*, tr_peer*, tr_block_index_t b) { reset_block(b); }),
          // unrequested
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

    auto const is_sequential = mediator_.is_sequential_download();

    auto blocks = small::vector<tr_block_index_t>{};
    blocks.reserve(n_wanted_blocks);

    // In sequential mode, process file by file in order
    if (is_sequential)
    {
        auto current_priority = tr_priority_t{};
        auto current_file_index = tr_piece_index_t{};
        bool have_current_file = false;

        for (auto const& candidate : candidates_)
        {
            if (std::size(blocks) >= n_wanted_blocks)
            {
                break;
            }

            // Set current file to first one we encounter
            if (!have_current_file)
            {
                current_priority = candidate.priority;
                current_file_index = candidate.file_index;
                have_current_file = true;
            }

            // If we moved to a different file, check if current file still has unrequested blocks
            if (candidate.priority != current_priority || candidate.file_index != current_file_index)
            {
                // If we got blocks from current file, stay with it
                if (!blocks.empty())
                {
                    break;
                }
                // Otherwise, move to next file
                current_priority = candidate.priority;
                current_file_index = candidate.file_index;
            }

            if (!peer_has_piece(candidate.piece) || candidate.unrequested.empty())
            {
                continue;
            }

            auto const n_to_add = std::min(std::size(candidate.unrequested), n_wanted_blocks - std::size(blocks));
            std::copy_n(std::rbegin(candidate.unrequested), n_to_add, std::back_inserter(blocks));
        }
    }
    else
    {
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

            auto const n_to_add = std::min(std::size(candidate.unrequested), n_wanted_blocks - std::size(blocks));
            std::copy_n(std::rbegin(candidate.unrequested), n_to_add, std::back_inserter(blocks));
        }
    }

    // Ensure the list of blocks are sorted
    // The list needs to be unique as well, but that should come naturally
    std::sort(std::begin(blocks), std::end(blocks));
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
