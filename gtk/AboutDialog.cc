// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "AboutDialog.h"

#include "GtkCompat.h"
#include "Utils.h"

#include <libtransmission/transmission.h>
#include <libtransmission/version.h>

#include <glibmm/i18n.h>
#include <glibmm/miscutils.h>
#include <glibmm/ustring.h>
#include <gtkmm/aboutdialog.h>

#include <memory>
#include <string>
#include <vector>

namespace
{

char const* const License =
    "Copyright 2005-2026. All code is copyrighted by the respective authors.\n"
    "\n"
    "Transmission can be redistributed and/or modified under the terms of the "
    "GNU GPL, versions 2 or 3, or by any future license endorsed by Mnemosyne LLC."
    "\n"
    "In addition, linking to and/or using OpenSSL is allowed.\n"
    "\n"
    "This program is distributed in the hope that it will be useful, "
    "but WITHOUT ANY WARRANTY; without even the implied warranty of "
    "MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n"
    "\n"
    "Some of Transmission's source files have more permissive licenses. "
    "Those files may, of course, be used on their own under their own terms.\n";

} // namespace

void gtr_show_about_dialog(Gtk::Window& parent)
{
    auto const uri = Glib::ustring("https://transmissionbt.com/");
    auto const authors = std::vector<Glib::ustring>({
        "Charles Kerr (Backend; GTK+)",
        "Mitchell Livingston (Backend; macOS)",
        "Mike Gelfand",
    });

    auto d = std::make_shared<Gtk::AboutDialog>();
    d->set_authors(authors);
    d->set_comments(_("A fast and easy BitTorrent client"));
    d->set_copyright(_("Copyright © The Transmission Project"));
    d->set_logo_icon_name("transmission");
    d->set_name(Glib::get_application_name());
    /* Translators: translate "translator-credits" as your name
       to have it appear in the credits in the "About"
       dialog */
    d->set_translator_credits(_("translator-credits"));
    d->set_version(LONG_VERSION_STRING);
    d->set_website(uri);
    d->set_website_label(uri);
    d->set_license(License);
    d->set_wrap_license(true);
    d->set_transient_for(parent);
    d->set_modal(true);
    gtr_window_on_close(*d, [d]() mutable { d.reset(); });
#if !GTKMM_CHECK_VERSION(4, 0, 0)
    d->signal_response().connect_notify([&dref = *d](int /*response*/) { dref.close(); });
#endif
    d->show();
}
