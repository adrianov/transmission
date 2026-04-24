// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "PiecesProgressBar.h"

#include "Percents.h"
#include "Prefs.h"
#include "Torrent.h"

#include <libtransmission/transmission.h>

#include <cairomm/context.h>
#include <cairomm/pattern.h>
#include <cairomm/refptr.h>
#include <cairomm/surface.h>
#include <gdkmm/rgba.h>
#include <glibmm/refptr.h>

#if GTKMM_CHECK_VERSION(4, 0, 0)
#include <glibmm/value.h>
#include <gtkmm/drawingarea.h>
#endif

#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

namespace
{

// Match the macOS client's proportions and limits from ProgressBarView.mm.
constexpr double kPiecesTotalPercent = 0.6;
constexpr int kMaxPieces = 18 * 18;
constexpr float kPieceCompleteEpsilon = 0.001F;

struct RgbaBytes
{
    std::uint8_t r;
    std::uint8_t g;
    std::uint8_t b;
    std::uint8_t a;
};

constexpr RgbaBytes to_bytes(double r, double g, double b, double a)
{
    return {
        static_cast<std::uint8_t>(std::clamp(r, 0.0, 1.0) * 255.0 + 0.5),
        static_cast<std::uint8_t>(std::clamp(g, 0.0, 1.0) * 255.0 + 0.5),
        static_cast<std::uint8_t>(std::clamp(b, 0.0, 1.0) * 255.0 + 0.5),
        static_cast<std::uint8_t>(std::clamp(a, 0.0, 1.0) * 255.0 + 0.5),
    };
}

// Colors chosen to mirror the macOS ProgressBarView palette.
constexpr RgbaBytes kBluePiece = to_bytes(0.0, 0.4, 0.8, 1.0);
constexpr RgbaBytes kOrangePiece = to_bytes(1.0, 0.5, 0.0, 1.0);
constexpr RgbaBytes kPieceBg = to_bytes(1.0, 1.0, 1.0, 1.0);
constexpr RgbaBytes kMagnetFill = to_bytes(0.85, 0.85, 0.85, 1.0);

void fill_rect(Cairo::RefPtr<Cairo::Context> const& context, Gdk::Rectangle const& area, Gdk::RGBA const& color)
{
    context->set_source_rgba(color.get_red(), color.get_green(), color.get_blue(), color.get_alpha());
    context->rectangle(area.get_x(), area.get_y(), area.get_width(), area.get_height());
    context->fill();
}

Gdk::RGBA make_rgba(RgbaBytes const& c)
{
    auto rgba = Gdk::RGBA();
    rgba.set_rgba(c.r / 255.0, c.g / 255.0, c.b / 255.0, c.a / 255.0);
    return rgba;
}

void draw_progress_portion(
    Cairo::RefPtr<Cairo::Context> const& context,
    Gdk::Rectangle const& area,
    double fraction,
    std::optional<Gdk::RGBA> const& tint)
{
    auto bar_color = Gdk::RGBA();
    bar_color.set_rgba(0.85, 0.85, 0.85, 1.0);

    auto filled_color = tint.value_or([]()
    {
        auto rgba = Gdk::RGBA();
        rgba.set_rgba(0.2, 0.55, 0.9, 1.0);
        return rgba;
    }());

    // Background
    fill_rect(context, area, bar_color);

    // Filled portion (left-aligned)
    auto const filled_width = static_cast<int>(area.get_width() * std::clamp(fraction, 0.0, 1.0) + 0.5);
    if (filled_width > 0)
    {
        auto filled_rect = area;
        filled_rect.set_width(filled_width);
        fill_rect(context, filled_rect, filled_color);
    }
}

void draw_pieces_strip(Cairo::RefPtr<Cairo::Context> const& context, Gdk::Rectangle const& area, Torrent& torrent)
{
    // Magnet links (metadata not yet known) get a solid fill.
    if (!torrent.get_has_metadata())
    {
        fill_rect(context, area, make_rgba(kMagnetFill));
        return;
    }

    auto const piece_count = static_cast<int>(std::min<size_t>(torrent.get_piece_count(), kMaxPieces));
    if (piece_count <= 0)
    {
        torrent.set_previous_finished_pieces({});
        fill_rect(context, area, make_rgba(kPieceBg));
        return;
    }

    // Build a 1-pixel-high strip: one pixel per piece bucket.
    auto surface = Cairo::ImageSurface::create(Cairo::FORMAT_ARGB32, piece_count, 1);
    auto const stride = surface->get_stride();
    auto* const data = surface->get_data();
    if (data == nullptr)
    {
        fill_rect(context, area, make_rgba(kPieceBg));
        return;
    }

    auto const* const previous = torrent.get_previous_finished_pieces();
    auto current_finished = std::vector<bool>(piece_count, false);

    // Cairo ARGB32 is premultiplied native-endian: B, G, R, A on little-endian.
    auto const write_pixel = [&](int x, std::uint8_t r, std::uint8_t g, std::uint8_t b, std::uint8_t a)
    {
        auto* const px = data + x * 4;
        // Premultiplication (alpha is 255 in our palette, so it's a no-op).
        px[0] = static_cast<std::uint8_t>((b * a + 127) / 255);
        px[1] = static_cast<std::uint8_t>((g * a + 127) / 255);
        px[2] = static_cast<std::uint8_t>((r * a + 127) / 255);
        px[3] = a;
    };

    if (torrent.get_all_downloaded())
    {
        for (int i = 0; i < piece_count; ++i)
        {
            current_finished[i] = true;
            write_pixel(i, kBluePiece.r, kBluePiece.g, kBluePiece.b, kBluePiece.a);
        }
    }
    else
    {
        auto percents = std::vector<float>(piece_count, 0.0F);
        torrent.get_amount_finished(percents.data(), piece_count);

        for (int i = 0; i < piece_count; ++i)
        {
            auto const pct = percents[i];
            if (pct >= 1.0F - kPieceCompleteEpsilon)
            {
                current_finished[i] = true;
                bool const is_new = previous != nullptr && static_cast<size_t>(i) < previous->size() &&
                    !(*previous)[i];
                auto const& c = is_new ? kOrangePiece : kBluePiece;
                write_pixel(i, c.r, c.g, c.b, c.a);
            }
            else
            {
                // Blend background -> blue based on piece completion fraction.
                auto const f = std::clamp(pct, 0.0F, 1.0F);
                auto const r = static_cast<std::uint8_t>((1.0F - f) * kPieceBg.r + f * kBluePiece.r + 0.5F);
                auto const g = static_cast<std::uint8_t>((1.0F - f) * kPieceBg.g + f * kBluePiece.g + 0.5F);
                auto const b = static_cast<std::uint8_t>((1.0F - f) * kPieceBg.b + f * kBluePiece.b + 0.5F);
                auto const a = static_cast<std::uint8_t>((1.0F - f) * kPieceBg.a + f * kBluePiece.a + 0.5F);
                write_pixel(i, r, g, b, a);
            }
        }
    }

    surface->mark_dirty();
    static_cast<void>(stride); // silence -Wunused when NDEBUG

    // Save current matrix / source so we can restore after stamping the strip.
    context->save();
    context->translate(area.get_x(), area.get_y());
    context->scale(static_cast<double>(area.get_width()) / piece_count, area.get_height());
    auto pattern = Cairo::SurfacePattern::create(surface);
    cairo_pattern_set_filter(pattern->cobj(), CAIRO_FILTER_NEAREST);
    context->set_source(pattern);
    context->rectangle(0, 0, piece_count, 1);
    context->fill();
    context->restore();

    // Remember which pieces are finished so we can flash orange on newly-completed pieces on next tick.
    bool has_any_finished = false;
    for (auto const f : current_finished)
    {
        if (f)
        {
            has_any_finished = true;
            break;
        }
    }
    torrent.set_previous_finished_pieces(has_any_finished ? std::move(current_finished) : std::vector<bool>{});
}

void draw_border(Cairo::RefPtr<Cairo::Context> const& context, Gdk::Rectangle const& area)
{
    context->save();
    context->set_source_rgba(0.0, 0.0, 0.0, 0.2);
    context->set_line_width(1.0);
    context->rectangle(area.get_x() + 0.5, area.get_y() + 0.5, area.get_width() - 1, area.get_height() - 1);
    context->stroke();
    context->restore();
}

} // namespace

namespace pieces_progress_bar
{

void draw(
    Cairo::RefPtr<Cairo::Context> const& context,
    Gdk::Rectangle const& area,
    Torrent& torrent,
    std::optional<Gdk::RGBA> const& tint,
    bool show_pieces)
{
    auto const fraction = static_cast<double>(torrent.get_percent_done().to_fraction());

    if (!show_pieces)
    {
        draw_progress_portion(context, area, fraction, tint);
        draw_border(context, area);
        torrent.set_previous_finished_pieces({});
        return;
    }

    // Split vertically: top ~60% pieces strip, bottom ~40% regular progress bar.
    auto const pieces_height = std::max(1, static_cast<int>(area.get_height() * kPiecesTotalPercent + 0.5));

    auto pieces_area = area;
    pieces_area.set_height(pieces_height);

    auto progress_area = area;
    progress_area.set_y(area.get_y() + pieces_height);
    progress_area.set_height(area.get_height() - pieces_height);

    draw_pieces_strip(context, pieces_area, torrent);
    draw_progress_portion(context, progress_area, fraction, tint);
    draw_border(context, area);
}

} // namespace pieces_progress_bar

#if GTKMM_CHECK_VERSION(4, 0, 0)

namespace
{

void pieces_progress_bar_class_init(void* /*cls*/, void* /*user_data*/)
{
    // No class-level hooks needed beyond the base DrawingArea.
}

} // namespace

class PiecesProgressBar::Impl
{
public:
    explicit Impl(PiecesProgressBar& widget);
    Impl(Impl&&) = delete;
    Impl(Impl const&) = delete;
    Impl& operator=(Impl&&) = delete;
    Impl& operator=(Impl const&) = delete;
    ~Impl();

    Glib::Property<Torrent*>& property_torrent()
    {
        return property_torrent_;
    }

    Glib::Property<double>& property_fraction()
    {
        return property_fraction_;
    }

private:
    void on_torrent_changed();
    void on_draw(Cairo::RefPtr<Cairo::Context> const& context, int width, int height);

private:
    PiecesProgressBar& widget_;

    Glib::Property<Torrent*> property_torrent_;
    Glib::Property<double> property_fraction_;

    gulong torrent_notify_handler_ = 0;
    GObject* torrent_gobj_ = nullptr;
};

PiecesProgressBar::Impl::Impl(PiecesProgressBar& widget)
    : widget_(widget)
    , property_torrent_(widget, "torrent", nullptr)
    , property_fraction_(widget, "fraction", 0.0)
{
    widget_.set_hexpand(true);
    widget_.set_valign(Gtk::Align::CENTER);
    widget_.set_content_height(16);
    widget_.add_css_class("tr-pieces-progress-bar");

    widget_.set_draw_func(sigc::mem_fun(*this, &Impl::on_draw));

    property_torrent_.get_proxy().signal_changed().connect(sigc::mem_fun(*this, &Impl::on_torrent_changed));
    property_fraction_.get_proxy().signal_changed().connect([this]() { widget_.queue_draw(); });

    on_torrent_changed();
}

PiecesProgressBar::Impl::~Impl()
{
    if (torrent_notify_handler_ != 0 && torrent_gobj_ != nullptr)
    {
        g_signal_handler_disconnect(torrent_gobj_, torrent_notify_handler_);
    }
}

void PiecesProgressBar::Impl::on_torrent_changed()
{
    if (torrent_notify_handler_ != 0 && torrent_gobj_ != nullptr)
    {
        g_signal_handler_disconnect(torrent_gobj_, torrent_notify_handler_);
        torrent_notify_handler_ = 0;
        torrent_gobj_ = nullptr;
    }

    auto* const torrent = property_torrent_.get_value();
    if (torrent == nullptr)
    {
        widget_.queue_draw();
        return;
    }

    // Redraw whenever the torrent's percent-done property changes.
    // Torrent emits notify::percent-done on every refresh tick where the
    // value actually changed, so this stays cheap.
    torrent_gobj_ = G_OBJECT(torrent->gobj());
    torrent_notify_handler_ = g_signal_connect(
        torrent_gobj_,
        "notify::percent-done",
        G_CALLBACK(+[](GObject* /*obj*/, GParamSpec* /*pspec*/, gpointer user_data)
                   { static_cast<PiecesProgressBar::Impl*>(user_data)->widget_.queue_draw(); }),
        this);

    widget_.queue_draw();
}

void PiecesProgressBar::Impl::on_draw(Cairo::RefPtr<Cairo::Context> const& context, int width, int height)
{
    auto* const torrent = property_torrent_.get_value();
    auto const area = Gdk::Rectangle(0, 0, width, height);

    if (torrent == nullptr)
    {
        draw_progress_portion(context, area, property_fraction_.get_value(), std::nullopt);
        draw_border(context, area);
        return;
    }

    auto const show_pieces = gtr_pref_flag_get(TR_KEY_show_pieces_bar);

    // Resolve a tint from the current style context (matches the
    // existing `tr-transfer-*` CSS classes used by the torrent row).
    auto tint = std::optional<Gdk::RGBA>();
    auto const& style = widget_.get_style_context();
    auto rgba = Gdk::RGBA();
    for (auto const& color_name : { "tr_transfer_down_color", "tr_transfer_up_color", "tr_transfer_idle_color" })
    {
        if (style->lookup_color(color_name, rgba))
        {
            tint = rgba;
            break;
        }
    }

    pieces_progress_bar::draw(context, area, *torrent, tint, show_pieces);
}

PiecesProgressBar::PiecesProgressBar()
    : Glib::ObjectBase(typeid(PiecesProgressBar))
    , ExtraClassInit(&pieces_progress_bar_class_init)
    , impl_(std::make_unique<Impl>(*this))
{
}

PiecesProgressBar::PiecesProgressBar(BaseObjectType* cast_item, Glib::RefPtr<Gtk::Builder> const& /*builder*/)
    : Glib::ObjectBase(typeid(PiecesProgressBar))
    , ExtraClassInit(&pieces_progress_bar_class_init)
    , Gtk::DrawingArea(cast_item)
    , impl_(std::make_unique<Impl>(*this))
{
}

PiecesProgressBar::~PiecesProgressBar() = default;

Glib::PropertyProxy<Torrent*> PiecesProgressBar::property_torrent()
{
    return impl_->property_torrent().get_proxy();
}

Glib::PropertyProxy<double> PiecesProgressBar::property_fraction()
{
    return impl_->property_fraction().get_proxy();
}

void PiecesProgressBar::ensure_registered()
{
    // Constructing a dummy instance forces Glib to register the custom
    // GType with GObject so that GtkBuilder can instantiate the widget
    // from a .ui file by its `gtkmm__CustomObject_...` name.
    [[maybe_unused]] static PiecesProgressBar const instance;
}

#endif // GTKMM_CHECK_VERSION(4, 0, 0)
