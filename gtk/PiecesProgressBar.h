// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#include "GtkCompat.h"

#include <cairomm/context.h>
#include <cairomm/refptr.h>
#include <gdkmm/rectangle.h>
#include <gdkmm/rgba.h>
#include <glibmm/extraclassinit.h>
#include <glibmm/property.h>
#include <glibmm/propertyproxy.h>
#include <glibmm/refptr.h>

#if GTKMM_CHECK_VERSION(4, 0, 0)
#include <gtkmm/drawingarea.h>
#else
#include <gtkmm/widget.h>
#endif

#include <memory>
#include <optional>

class Torrent;

#if GTKMM_CHECK_VERSION(4, 0, 0)

// A small Cairo-rendered widget that reproduces macOS's two-strip
// progress visualization (pieces strip on top, progress strip below).
//
// Drawing is driven off the bound Torrent's notify signals so that every
// refresh of the torrent model invalidates the widget.
class PiecesProgressBar
    : public Glib::ExtraClassInit
    , public Gtk::DrawingArea
{
public:
    PiecesProgressBar();
    PiecesProgressBar(BaseObjectType* cast_item, Glib::RefPtr<Gtk::Builder> const& builder);
    PiecesProgressBar(PiecesProgressBar&&) = delete;
    PiecesProgressBar(PiecesProgressBar const&) = delete;
    PiecesProgressBar& operator=(PiecesProgressBar&&) = delete;
    PiecesProgressBar& operator=(PiecesProgressBar const&) = delete;
    ~PiecesProgressBar() override;

    Glib::PropertyProxy<Torrent*> property_torrent();
    Glib::PropertyProxy<double> property_fraction();

    // Ensures the custom GType is registered with GObject so that
    // GtkBuilder can instantiate the widget from a .ui file by name.
    static void ensure_registered();

private:
    class Impl;
    std::unique_ptr<Impl> const impl_;
};

#endif // GTKMM_CHECK_VERSION(4, 0, 0)

namespace pieces_progress_bar
{

// Shared drawing routine. Both the GTK4 widget and the GTK3 cell
// renderer funnel through here so the look is identical across versions.
void draw(
    Cairo::RefPtr<Cairo::Context> const& context,
    Gdk::Rectangle const& area,
    Torrent& torrent,
    std::optional<Gdk::RGBA> const& tint,
    bool show_pieces);

} // namespace pieces_progress_bar
