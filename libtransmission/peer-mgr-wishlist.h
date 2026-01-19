// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#ifndef LIBTRANSMISSION_PEER_MODULE
#error only the libtransmission peer module should #include this header.
#endif

#include <cstddef> // size_t
#include <functional>
#include <memory>
#include <vector>

#include "libtransmission/transmission.h"

#include "libtransmission/observable.h"
#include "libtransmission/utils.h"

class tr_bitfield;
struct tr_peer;

/**
 * Figures out what blocks we want to request next.
 */
class Wishlist
{
public:
    struct Mediator
    {
        [[nodiscard]] virtual bool client_has_piece(tr_piece_index_t piece) const = 0;
        [[nodiscard]] virtual bool client_wants_piece(tr_piece_index_t piece) const = 0;
        [[nodiscard]] virtual tr_piece_index_t file_index_for_piece(tr_piece_index_t piece) const = 0;
        [[nodiscard]] virtual tr_block_span_t block_span(tr_piece_index_t piece) const = 0;
        [[nodiscard]] virtual tr_piece_index_t piece_count() const = 0;
        [[nodiscard]] virtual tr_priority_t priority(tr_piece_index_t piece) const = 0;
        [[nodiscard]] virtual tr_bitfield const& blocks() const = 0;

        [[nodiscard]] virtual libtransmission::ObserverTag observe_files_wanted_changed(
            libtransmission::SimpleObservable<tr_torrent*, tr_file_index_t const*, tr_file_index_t, bool>::Observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_peer_disconnect(
            libtransmission::SimpleObservable<tr_torrent*, tr_bitfield const&, tr_bitfield const&>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_got_bad_piece(
            libtransmission::SimpleObservable<tr_torrent*, tr_piece_index_t>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_got_block(
            libtransmission::SimpleObservable<tr_torrent*, tr_block_index_t>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_got_choke(
            libtransmission::SimpleObservable<tr_torrent*, tr_bitfield const&>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_got_reject(
            libtransmission::SimpleObservable<tr_torrent*, tr_peer*, tr_block_index_t>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_piece_completed(
            libtransmission::SimpleObservable<tr_torrent*, tr_piece_index_t>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_priority_changed(
            libtransmission::SimpleObservable<tr_torrent*, tr_file_index_t const*, tr_file_index_t, tr_priority_t>::Observer
                observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_sent_cancel(
            libtransmission::SimpleObservable<tr_torrent*, tr_peer*, tr_block_index_t>::Observer observer) = 0;
        [[nodiscard]] virtual libtransmission::ObserverTag observe_sent_request(
            libtransmission::SimpleObservable<tr_torrent*, tr_peer*, tr_block_span_t>::Observer observer) = 0;

        virtual ~Mediator() = default;
    };

    explicit Wishlist(Mediator& mediator_in);
    ~Wishlist();

    // the next blocks that we should request from a peer
    [[nodiscard]] std::vector<tr_block_span_t> next(
        size_t n_wanted_blocks,
        std::function<bool(tr_piece_index_t)> const& peer_has_piece);

    // faster version for seeds (no per-piece check needed)
    [[nodiscard]] std::vector<tr_block_span_t> next(size_t n_wanted_blocks);

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};
