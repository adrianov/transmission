// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
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
// Converts sorted block indices into contiguous spans
[[nodiscard]] std::vector<tr_block_span_t> make_spans(small::vector<tr_block_index_t> const& blocks)
{
    if (std::empty(blocks))
    {
        return {};
    }

    auto spans = std::vector<tr_block_span_t>{};
    auto span_begin = blocks.front();

    for (size_t i = 1; i < blocks.size(); ++i)
    {
        if (blocks[i] != blocks[i - 1] + 1)
        {
            spans.push_back({ span_begin, blocks[i - 1] + 1 });
            span_begin = blocks[i];
        }
    }
    spans.push_back({ span_begin, blocks.back() + 1 });

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
        tr_block_span_t raw_block_span;

        // Sorted descending so smaller block indices can be taken from end
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
    // Adds blocks for endgame mode (re-request blocks that are still missing)
    void add_endgame_blocks(Candidate const& candidate, size_t n_wanted, small::vector<tr_block_index_t>& blocks) const
    {
        for (auto block = candidate.block_span.begin; block < candidate.block_span.end && blocks.size() < n_wanted; ++block)
        {
            if (!mediator_.client_has_block(block))
            {
                blocks.push_back(block);
            }
        }
    }

    void requested_block_span(tr_block_span_t const span)
    {
        for (auto block = span.begin; block < span.end;)
        {
            auto const it = find_by_block(block);
            if (it == std::end(candidates_))
            {
                break;
            }

            // Erase blocks in [span.begin, span.end) from this candidate's unrequested set
            auto& unreq = it->unrequested;
            for (auto b = std::max(span.begin, it->block_span.begin); b < std::min(span.end, it->block_span.end); ++b)
            {
                unreq.erase(b);
            }

            block = it->block_span.end;
        }
    }

    void reset_block(tr_block_index_t const block)
    {
        if (auto const it = find_by_block(block); it != std::end(candidates_))
        {
            it->unrequested.insert(block);
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

            for (auto block = begin; block < end; ++block)
            {
                if (requests.test(block))
                {
                    candidate.unrequested.insert(block);
                }
            }
        }
    }

    void client_got_block(tr_block_index_t const block)
    {
        if (auto const it = find_by_block(block); it != std::end(candidates_))
        {
            it->unrequested.erase(block);
        }
    }

    void got_bad_piece(tr_piece_index_t const piece)
    {
        auto const it = find_by_piece(piece);
        if (it == std::end(candidates_))
        {
            return;
        }

        it->block_span = it->raw_block_span;
        it->unrequested.clear();
        for (auto block = it->block_span.begin; block < it->block_span.end; ++block)
        {
            if (!mediator_.client_has_block(block))
            {
                it->unrequested.insert(block);
            }
        }
    }

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
        auto const n_pieces = mediator_.piece_count();

        auto new_candidates = CandidateVec{};
        new_candidates.reserve(n_pieces);

        for (tr_piece_index_t piece = 0U; piece < n_pieces; ++piece)
        {
            if (mediator_.client_wants_piece(piece) && !mediator_.client_has_piece(piece))
            {
                new_candidates.emplace_back(piece, &mediator_);
            }
        }

        std::sort(std::begin(new_candidates), std::end(new_candidates));

        // Handle block span overlaps between consecutive pieces
        for (size_t i = 1; i < new_candidates.size(); ++i)
        {
            auto& prev = new_candidates[i - 1];
            auto& curr = new_candidates[i];

            if (prev.block_span.end > curr.block_span.begin)
            {
                for (auto block = curr.block_span.begin; block < prev.block_span.end; ++block)
                {
                    curr.unrequested.erase(block);
                }
                curr.block_span.begin = prev.block_span.end;
            }
        }

        candidates_ = std::move(new_candidates);
    }

    void remove_piece(tr_piece_index_t const piece)
    {
        if (auto const it = find_by_piece(piece); it != std::end(candidates_))
        {
            candidates_.erase(it);
        }
    }

    void recalculate_priority()
    {
        for (auto& candidate : candidates_)
        {
            candidate.priority = mediator_.priority(candidate.piece);
            candidate.file_index = mediator_.file_index_for_piece(candidate.piece);
        }

        std::sort(std::begin(candidates_), std::end(candidates_));
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

    auto const is_sequential = mediator_.is_sequential_download();
    auto blocks = small::vector<tr_block_index_t>{};
    blocks.reserve(n_wanted_blocks);

    // Track current file context for sequential mode
    auto current_priority = tr_priority_t{};
    auto current_file_index = tr_piece_index_t{};
    auto have_current_file = false;

    // Returns true if we should stop iterating (file boundary crossed with blocks collected)
    auto const check_sequential_boundary = [&](Candidate const& candidate) -> bool
    {
        if (!is_sequential)
        {
            return false;
        }

        if (!have_current_file)
        {
            current_priority = candidate.priority;
            current_file_index = candidate.file_index;
            have_current_file = true;
            return false;
        }

        if (candidate.priority != current_priority || candidate.file_index != current_file_index)
        {
            if (!blocks.empty())
            {
                return true;
            }
            current_priority = candidate.priority;
            current_file_index = candidate.file_index;
        }
        return false;
    };

    // First pass: collect unrequested blocks
    for (auto const& candidate : candidates_)
    {
        if (blocks.size() >= n_wanted_blocks || check_sequential_boundary(candidate))
        {
            break;
        }

        if (!peer_has_piece(candidate.piece) || candidate.unrequested.empty())
        {
            continue;
        }

        auto const n_to_add = std::min(candidate.unrequested.size(), n_wanted_blocks - blocks.size());
        std::copy_n(std::rbegin(candidate.unrequested), n_to_add, std::back_inserter(blocks));
    }

    // Endgame fallback: re-request blocks that haven't arrived yet
    if (blocks.empty())
    {
        have_current_file = false;

        for (auto const& candidate : candidates_)
        {
            if (blocks.size() >= n_wanted_blocks)
            {
                break;
            }

            if (!peer_has_piece(candidate.piece))
            {
                continue;
            }

            if (check_sequential_boundary(candidate))
            {
                break;
            }

            add_endgame_blocks(candidate, n_wanted_blocks, blocks);
        }
    }

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
