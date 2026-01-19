// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cstddef>
#include <functional>
#include <utility>
#include <vector>

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
    auto span_begin = blocks[0];
    auto span_end = span_begin;

    for (size_t i = 1; i < std::size(blocks); ++i)
    {
        if (blocks[i] == span_end + 1)
        {
            ++span_end;
        }
        else
        {
            spans.push_back({ span_begin, span_end + 1 });
            span_begin = blocks[i];
            span_end = span_begin;
        }
    }
    spans.push_back({ span_begin, span_end + 1 });
    return spans;
}
} // namespace

class Wishlist::Impl
{
    struct Candidate
    {
        tr_piece_index_t piece;
        tr_piece_index_t file_index;
        tr_block_span_t block_span;
        tr_priority_t priority;
        uint16_t available; // blocks not yet owned by client

        [[nodiscard]] constexpr auto sort_key() const noexcept
        {
            return std::tuple{ -priority, file_index, piece };
        }

        [[nodiscard]] constexpr bool operator<(Candidate const& that) const noexcept
        {
            return sort_key() < that.sort_key();
        }
    };

    using CandidateVec = std::vector<Candidate>;

public:
    explicit Impl(Mediator& mediator_in);

    [[nodiscard]] std::vector<tr_block_span_t> next(
        size_t n_wanted_blocks,
        std::function<bool(tr_piece_index_t)> const& peer_has_piece);

    [[nodiscard]] std::vector<tr_block_span_t> next(size_t n_wanted_blocks);

private:
    void candidate_list_upkeep()
    {
        auto const n_pieces = mediator_.piece_count();

        candidates_.clear();
        candidates_.reserve(n_pieces);
        piece_to_index_.assign(n_pieces, SIZE_MAX);

        for (tr_piece_index_t piece = 0U; piece < n_pieces; ++piece)
        {
            if (mediator_.client_wants_piece(piece) && !mediator_.client_has_piece(piece))
            {
                auto const block_span = mediator_.block_span(piece);
                uint16_t available = 0;
                for (auto block = block_span.begin; block < block_span.end; ++block)
                {
                    if (!mediator_.client_has_block(block))
                    {
                        ++available;
                    }
                }
                if (available == 0)
                {
                    continue;
                }

                piece_to_index_[piece] = candidates_.size();
                auto& c = candidates_.emplace_back();
                c.piece = piece;
                c.file_index = mediator_.file_index_for_piece(piece);
                c.block_span = block_span;
                c.priority = mediator_.priority(piece);
                c.available = available;
            }
        }

        std::sort(std::begin(candidates_), std::end(candidates_));

        for (size_t i = 0; i < candidates_.size(); ++i)
        {
            piece_to_index_[candidates_[i].piece] = i;
        }
    }

    void on_got_block(tr_block_index_t block)
    {
        requested_.unset(block);

        // Find which candidate this block belongs to and decrement available
        auto const piece = mediator_.block_piece(block);
        if (piece < piece_to_index_.size())
        {
            auto const idx = piece_to_index_[piece];
            if (idx != SIZE_MAX && idx < candidates_.size())
            {
                auto& c = candidates_[idx];
                if (c.available > 0)
                {
                    --c.available;
                }
            }
        }
    }

    void remove_piece(tr_piece_index_t const piece)
    {
        if (piece >= piece_to_index_.size())
        {
            return;
        }
        auto const idx = piece_to_index_[piece];
        if (idx == SIZE_MAX || idx >= candidates_.size())
        {
            return;
        }

        auto const& c = candidates_[idx];
        requested_.unset_span(c.block_span.begin, c.block_span.end);

        piece_to_index_[piece] = SIZE_MAX;

        if (idx != candidates_.size() - 1)
        {
            auto const last_piece = candidates_.back().piece;
            std::swap(candidates_[idx], candidates_.back());
            piece_to_index_[last_piece] = idx;
        }
        candidates_.pop_back();
    }

    void recalculate_priority()
    {
        for (auto& candidate : candidates_)
        {
            candidate.priority = mediator_.priority(candidate.piece);
        }
        std::sort(std::begin(candidates_), std::end(candidates_));

        for (size_t i = 0; i < candidates_.size(); ++i)
        {
            piece_to_index_[candidates_[i].piece] = i;
        }
    }

    CandidateVec candidates_;
    std::vector<size_t> piece_to_index_;
    tr_bitfield requested_;
    std::array<libtransmission::ObserverTag, 10U> const tags_;
    Mediator& mediator_;
};

Wishlist::Impl::Impl(Mediator& mediator_in)
    : requested_{ mediator_in.piece_count() > 0 ? mediator_in.block_span(mediator_in.piece_count() - 1).end : 0 }
    , tags_{ {
          mediator_in.observe_files_wanted_changed([this](tr_torrent*, tr_file_index_t const*, tr_file_index_t, bool)
                                                   { candidate_list_upkeep(); }),
          mediator_in.observe_peer_disconnect(
              [this](tr_torrent*, tr_bitfield const&, tr_bitfield const& requests)
              {
                  for (auto const& c : candidates_)
                  {
                      if (requests.count(c.block_span.begin, c.block_span.end) == 0)
                      {
                          continue;
                      }
                      for (auto block = c.block_span.begin; block < c.block_span.end; ++block)
                      {
                          if (requests.test(block))
                          {
                              requested_.unset(block);
                          }
                      }
                  }
              }),
          mediator_in.observe_got_bad_piece([](tr_torrent*, tr_piece_index_t) {}),
          mediator_in.observe_got_block([this](tr_torrent*, tr_block_index_t b) { on_got_block(b); }),
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
    candidate_list_upkeep();
}

std::vector<tr_block_span_t> Wishlist::Impl::next(size_t const n_wanted_blocks)
{
    if (n_wanted_blocks == 0U || candidates_.empty())
    {
        return {};
    }

    auto blocks = small::vector<tr_block_index_t>{};
    blocks.reserve(n_wanted_blocks);

    // First pass: unrequested blocks only
    for (auto const& candidate : candidates_)
    {
        if (std::size(blocks) >= n_wanted_blocks)
        {
            break;
        }
        if (candidate.available == 0)
        {
            continue;
        }
        for (auto block = candidate.block_span.begin; block < candidate.block_span.end; ++block)
        {
            if (std::size(blocks) >= n_wanted_blocks)
            {
                break;
            }
            if (!requested_.test(block) && !mediator_.client_has_block(block))
            {
                blocks.push_back(block);
            }
        }
    }

    // Second pass: endgame - any missing block
    if (std::size(blocks) < n_wanted_blocks)
    {
        for (auto const& candidate : candidates_)
        {
            if (std::size(blocks) >= n_wanted_blocks)
            {
                break;
            }
            if (candidate.available == 0)
            {
                continue;
            }
            for (auto block = candidate.block_span.begin; block < candidate.block_span.end; ++block)
            {
                if (std::size(blocks) >= n_wanted_blocks)
                {
                    break;
                }
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

    // First pass: unrequested blocks only
    for (auto const& candidate : candidates_)
    {
        if (std::size(blocks) >= n_wanted_blocks)
        {
            break;
        }
        if (candidate.available == 0 || !peer_has_piece(candidate.piece))
        {
            continue;
        }
        for (auto block = candidate.block_span.begin; block < candidate.block_span.end; ++block)
        {
            if (std::size(blocks) >= n_wanted_blocks)
            {
                break;
            }
            if (!requested_.test(block) && !mediator_.client_has_block(block))
            {
                blocks.push_back(block);
            }
        }
    }

    // Second pass: endgame - any missing block
    if (std::size(blocks) < n_wanted_blocks)
    {
        for (auto const& candidate : candidates_)
        {
            if (std::size(blocks) >= n_wanted_blocks)
            {
                break;
            }
            if (candidate.available == 0 || !peer_has_piece(candidate.piece))
            {
                continue;
            }
            for (auto block = candidate.block_span.begin; block < candidate.block_span.end; ++block)
            {
                if (std::size(blocks) >= n_wanted_blocks)
                {
                    break;
                }
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

std::vector<tr_block_span_t> Wishlist::next(size_t const n_wanted_blocks)
{
    return impl_->next(n_wanted_blocks);
}
