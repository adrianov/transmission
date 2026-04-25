// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "InspectorPiecesView.h"

#include <libtransmission/transmission.h>

#include <cairomm/context.h>
#include <glibmm/i18n.h>
#include <pango/pangocairo.h>
#include <pangomm/layout.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <string_view>

namespace
{

// pieces_view.mm, ProgressBarView.mm, PiecesProgressBar.cc
double constexpr kPad = 1.0;
int8_t constexpr kHighPeers = 10;

struct Rgba
{
    double r, g, b, a;
};

Rgba const kBlue{ 0.0, 0.4, 0.8, 1.0 };
Rgba const kOrange{ 1.0, 0.5, 0.0, 1.0 };
Rgba const kPieceBg{ 1.0, 1.0, 1.0, 1.0 };
Rgba const kHigh{ 0.5, 0.5, 0.5, 1.0 };

void fill_rect(Cairo::RefPtr<Cairo::Context> const& cr, double x, double y, double w, double h, Rgba const& c)
{
    cr->set_source_rgba(c.r, c.g, c.b, c.a);
    cr->rectangle(x, y, w, h);
    cr->fill();
}

Rgba mix(Rgba a, Rgba b, double f)
{
    f = std::clamp(f, 0.0, 1.0);
    return {
        (1.0 - f) * a.r + f * b.r,
        (1.0 - f) * a.g + f * b.g,
        (1.0 - f) * a.b + f * b.b,
        (1.0 - f) * a.a + f * b.a,
    };
}

bool cmp_done_f(float v)
{
    return v >= 1.0F;
}

bool cmp_empty_f(float v)
{
    return v <= 0.0F;
}

Rgba color_complete(float old_v, float new_v, Rgba const& bg, bool no_blink)
{
    if (cmp_done_f(new_v))
    {
        if (no_blink || cmp_done_f(old_v))
        {
            return kBlue;
        }
        return kOrange;
    }
    if (cmp_empty_f(new_v))
    {
        if (no_blink || cmp_empty_f(old_v))
        {
            return bg;
        }
        return kOrange;
    }
    return mix(bg, kBlue, static_cast<double>(std::clamp(new_v, 0.0F, 1.0F)));
}

bool cmp_done_i(int8_t v)
{
    return v == static_cast<int8_t>(-1);
}

bool cmp_empty_i(int8_t v)
{
    return v == 0;
}

bool cmp_high_i(int8_t v)
{
    return v >= kHighPeers;
}

Rgba color_availability(int8_t old_v, int8_t new_v, Rgba const& bg, bool no_blink)
{
    if (cmp_done_i(new_v))
    {
        if (no_blink || cmp_done_i(old_v))
        {
            return kBlue;
        }
        return kOrange;
    }
    if (cmp_empty_i(new_v))
    {
        if (no_blink || cmp_empty_i(old_v))
        {
            return bg;
        }
        return kOrange;
    }
    if (cmp_high_i(new_v))
    {
        if (no_blink || cmp_high_i(old_v))
        {
            return kHigh;
        }
        return kOrange;
    }
    auto const percent = static_cast<double>(static_cast<int8_t>(new_v)) / static_cast<double>(kHighPeers);
    return mix(bg, kHigh, percent);
}

void draw_centered_message(
    Gtk::Widget& widget,
    Cairo::RefPtr<Cairo::Context> const& cr,
    Gdk::Rectangle const& area,
    Glib::ustring const& message)
{
    Glib::RefPtr<Pango::Layout> const layout = widget.create_pango_layout(message);
    int w = 0;
    int h = 0;
    layout->get_pixel_size(w, h);
    cr->set_source_rgba(0.45, 0.45, 0.45, 1.0);
    cr->move_to(area.get_x() + (area.get_width() - w) / 2, area.get_y() + (area.get_height() - h) / 2);
    pango_cairo_update_layout(cr->cobj(), layout->gobj());
    pango_cairo_show_layout(cr->cobj(), layout->gobj());
}

} // namespace

void inspector_pieces::draw(
    Gtk::Widget& widget,
    Cairo::RefPtr<Cairo::Context> const& cr,
    Gdk::Rectangle const& area,
    tr_torrent const* tor,
    bool show_availability,
    State& state)
{
    // match PiecesView drawRect: dim plate behind cells
    cr->set_source_rgba(0.0, 0.0, 0.0, 0.2);
    cr->rectangle(area.get_x(), area.get_y(), area.get_width(), area.get_height());
    cr->fill();

    if (tor == nullptr)
    {
        state.reset();
        draw_centered_message(widget, cr, area, _("Select a single torrent to view piece map."));
        return;
    }

    if (!tr_torrentHasMetadata(tor))
    {
        state.reset();
        draw_centered_message(widget, cr, area, _("Waiting for metadata…"));
        return;
    }

    auto const view = tr_torrentView(tor);
    if (view.hash_string == nullptr)
    {
        return;
    }

    std::string_view const hs{ view.hash_string };
    if (state.last_hash != hs)
    {
        state.reset();
        state.last_hash = std::string{ hs };
    }

    if (view.n_pieces == 0)
    {
        return;
    }

    int const num_cells = static_cast<int>(std::min(
        static_cast<int>(view.n_pieces), kMaxCells));
    Rgba const bg = kPieceBg;

    std::array<int8_t, kMaxCells> cur_avail{};
    std::array<float, kMaxCells> cur_complete{};

    tr_torrentAvailability(tor, cur_avail.data(), static_cast<int>(num_cells));
    tr_torrentAmountFinished(tor, cur_complete.data(), num_cells);

    bool const no_blink = state.is_first;
    if (state.is_first)
    {
        state.is_first = false;
    }

    int const across = static_cast<int>(std::ceil(std::sqrt(static_cast<double>(num_cells))));
    double const full_w = static_cast<double>(std::min(area.get_width(), area.get_height()));
    if (full_w < 4.0)
    {
        return;
    }

    auto const cell_w = static_cast<int>((full_w - (across + 1) * kPad) / across);
    if (cell_w < 1)
    {
        return;
    }
    int const extra_border = static_cast<int>((full_w - ((cell_w + kPad) * across + kPad)) / 2.0);

    double const ax = area.get_x();
    double const ay = area.get_y();
    for (int i = 0; i < num_cells; ++i)
    {
        int const row = i / across;
        int const col = i % across;
        double const x = ax + kPad + extra_border + col * (cell_w + kPad);
        double const y = ay + kPad + extra_border + row * (cell_w + kPad);

        Rgba c;
        if (show_availability)
        {
            c = color_availability(
                state.prev_available[static_cast<size_t>(i)],
                cur_avail[static_cast<size_t>(i)],
                bg,
                no_blink);
        }
        else
        {
            c = color_complete(
                state.prev_complete[static_cast<size_t>(i)],
                cur_complete[static_cast<size_t>(i)],
                bg,
                no_blink);
        }
        fill_rect(cr, x, y, static_cast<double>(cell_w), static_cast<double>(cell_w), c);
    }

    for (int i = 0; i < num_cells; ++i)
    {
        state.prev_available[static_cast<size_t>(i)] = cur_avail[static_cast<size_t>(i)];
        state.prev_complete[static_cast<size_t>(i)] = cur_complete[static_cast<size_t>(i)];
    }
    for (size_t i = static_cast<size_t>(num_cells); i < kMaxCells; ++i)
    {
        state.prev_available[i] = 0;
        state.prev_complete[i] = 0.0F;
    }
}
