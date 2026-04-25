// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#include "GtkCompat.h"

#include <cairomm/refptr.h>
#include <gdkmm/rectangle.h>
#include <gtkmm/widget.h>

#include <array>
#include <string>

struct tr_torrent;

/**
 * Renders the macOS Torrent Inspector–style piece grid (at most 18×18 buckets)
 * for the GTK Properties → Information page.
 */
namespace inspector_pieces
{

// Matches macOS PiecesView (PiecesView.mm) and list pieces strip (kMaxPieces).
int constexpr kMaxAcross = 18;
int constexpr kMaxCells = kMaxAcross * kMaxAcross;

struct State
{
    std::array<int8_t, kMaxCells> prev_available{};
    std::array<float, kMaxCells> prev_complete{};
    std::string last_hash; // tr_torrent_view::hash_string (string compare, not pointer identity)
    bool is_first = true; // no blink the first time after reset (matches macOS PiecesView)

    void reset()
    {
        prev_available = {};
        prev_complete = {};
        last_hash.clear();
        is_first = true;
    }
};

void draw(
    Gtk::Widget& widget,
    Cairo::RefPtr<Cairo::Context> const& cr,
    Gdk::Rectangle const& area,
    tr_torrent const* tor,
    bool show_availability,
    State& state);

} // namespace inspector_pieces
