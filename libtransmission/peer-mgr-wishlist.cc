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
#include "libtransmission/peer-mgr-wishlist.h"

class Wishlist::Impl
{
    struct Candidate
    {
        tr_piece_index_t piece;
        tr_piece_index_t file_index;
        tr_block_span_t block_span;
        tr_priority_t priority;
        bool is_in_file_tail; // last 20 MB of file - prioritized for video playback
        bool is_in_priority_file; // index files (IFO, BUP, index.bdmv) - prioritized for disc playback

        // Sort by: priority (high first), file index, priority files (true first), file tail (true first), piece index
        [[nodiscard]] constexpr auto sort_key() const noexcept
        {
            return std::tuple{ -priority, file_index, !is_in_priority_file, !is_in_file_tail, piece };
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

private:
    void rebuild_candidates()
    {
        auto const n_pieces = mediator_.piece_count();
        candidates_.clear();
        candidates_.reserve(n_pieces);

        for (tr_piece_index_t piece = 0U; piece < n_pieces; ++piece)
        {
            if (mediator_.client_wants_piece(piece) && !mediator_.client_has_piece(piece))
            {
                candidates_.push_back(
                    {
                        piece,
                        mediator_.file_index_for_piece(piece),
                        mediator_.block_span(piece),
                        mediator_.priority(piece),
                        mediator_.is_piece_in_file_tail(piece),
                        mediator_.is_piece_in_priority_file(piece),
                    });
            }
        }

        std::sort(std::begin(candidates_), std::end(candidates_));
    }

    void remove_piece(tr_piece_index_t const piece)
    {
        auto const it = std::find_if(
            std::begin(candidates_),
            std::end(candidates_),
            [piece](auto const& c) { return c.piece == piece; });

        if (it != std::end(candidates_))
        {
            candidates_.erase(it);
        }
    }

    void recalculate_priority()
    {
        for (auto& c : candidates_)
        {
            c.priority = mediator_.priority(c.piece);
            c.file_index = mediator_.file_index_for_piece(c.piece);
        }
        std::sort(std::begin(candidates_), std::end(candidates_));
    }

    std::vector<Candidate> candidates_;
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
                                              { requested_.unset_from(requests); }),
          mediator_in.observe_got_bad_piece([](tr_torrent*, tr_piece_index_t) {}),
          mediator_in.observe_got_block([this](tr_torrent*, tr_block_index_t b) { requested_.unset(b); }),
          mediator_in.observe_got_choke([this](tr_torrent*, tr_bitfield const& requests) { requested_.unset_from(requests); }),
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

std::vector<tr_block_span_t> Wishlist::Impl::next(
    size_t const n_wanted_blocks,
    std::function<bool(tr_piece_index_t)> const& peer_has_piece)
{
    if (n_wanted_blocks == 0U || candidates_.empty())
    {
        return {};
    }

    auto const is_sequential = mediator_.is_sequential_download();
    auto spans = std::vector<tr_block_span_t>{};
    spans.reserve(n_wanted_blocks);
    size_t count = 0;

    // Track blocks already added (for overlapping piece spans)
    auto added = tr_bitfield{ requested_.size() };

    // Track file context for sequential mode
    auto current_priority = tr_priority_t{};
    auto current_file_index = tr_piece_index_t{};
    auto have_current_file = false;

    auto const at_sequential_boundary = [&](Candidate const& c) -> bool
    {
        if (!is_sequential)
        {
            return false;
        }

        if (!have_current_file)
        {
            current_priority = c.priority;
            current_file_index = c.file_index;
            have_current_file = true;
            return false;
        }

        if (c.priority != current_priority || c.file_index != current_file_index)
        {
            if (count > 0)
            {
                return true;
            }
            current_priority = c.priority;
            current_file_index = c.file_index;
        }
        return false;
    };

    // First pass: unrequested blocks
    for (auto const& c : candidates_)
    {
        if (count >= n_wanted_blocks || at_sequential_boundary(c))
        {
            break;
        }

        if (!peer_has_piece(c.piece))
        {
            continue;
        }

        for (auto block = c.block_span.begin; block < c.block_span.end && count < n_wanted_blocks;)
        {
            // Skip blocks that are already requested, owned, or added
            while (block < c.block_span.end &&
                   (requested_.test(block) || mediator_.client_has_block(block) || added.test(block)))
            {
                ++block;
            }

            if (block >= c.block_span.end)
            {
                break;
            }

            auto const span_begin = block++;

            // Extend span
            while (block < c.block_span.end && count + (block - span_begin) < n_wanted_blocks && !requested_.test(block) &&
                   !mediator_.client_has_block(block) && !added.test(block))
            {
                ++block;
            }

            spans.push_back({ span_begin, block });
            added.set_span(span_begin, block);
            count += block - span_begin;
        }
    }

    // Second pass: endgame - re-request missing blocks (only if first pass found nothing)
    if (count == 0)
    {
        have_current_file = false;

        for (auto const& c : candidates_)
        {
            if (count >= n_wanted_blocks || at_sequential_boundary(c))
            {
                break;
            }

            if (!peer_has_piece(c.piece))
            {
                continue;
            }

            for (auto block = c.block_span.begin; block < c.block_span.end && count < n_wanted_blocks;)
            {
                // Skip blocks that are owned or already added
                while (block < c.block_span.end && (mediator_.client_has_block(block) || added.test(block)))
                {
                    ++block;
                }

                if (block >= c.block_span.end)
                {
                    break;
                }

                auto const span_begin = block++;

                // Extend span
                while (block < c.block_span.end && count + (block - span_begin) < n_wanted_blocks &&
                       !mediator_.client_has_block(block) && !added.test(block))
                {
                    ++block;
                }

                spans.push_back({ span_begin, block });
                added.set_span(span_begin, block);
                count += block - span_begin;
            }
        }
    }

    // Merge adjacent spans
    if (spans.size() > 1)
    {
        std::sort(spans.begin(), spans.end(), [](auto const& a, auto const& b) { return a.begin < b.begin; });

        auto merged = std::vector<tr_block_span_t>{};
        merged.push_back(spans.front());

        for (size_t i = 1; i < spans.size(); ++i)
        {
            if (spans[i].begin <= merged.back().end)
            {
                merged.back().end = std::max(merged.back().end, spans[i].end);
            }
            else
            {
                merged.push_back(spans[i]);
            }
        }

        return merged;
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
