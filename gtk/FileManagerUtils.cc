// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "Utils.h"

#include "GtkCompat.h"

#include <giomm/appinfo.h>
#include <giomm/dbusconnection.h>
#include <giomm/file.h>
#include <glibmm/fileutils.h>
#include <glibmm/i18n.h>
#include <glibmm/spawn.h>

#include <string>
#include <vector>

namespace
{

bool try_reveal_with_file_manager_dbus(std::string const& path)
{
    try
    {
        auto const connection = Gio::DBus::Connection::get_sync(TR_GIO_DBUS_BUS_TYPE(SESSION));
        auto const file = Gio::File::create_for_path(path);
        std::vector<Glib::ustring> const uris = { file->get_uri() };
        connection->call_sync(
            "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1",
            "ShowItems",
            Glib::VariantContainerBase::create_tuple({
                Glib::Variant<std::vector<Glib::ustring>>::create(uris),
                Glib::Variant<Glib::ustring>::create(""),
            }),
            "org.freedesktop.FileManager1",
            1000);
        return true;
    }
    catch (Glib::Error const&)
    {
        return false;
    }
}

} // namespace

void gtr_open_file(std::string const& path)
{
    gtr_open_uri(Gio::File::create_for_path(path)->get_uri());
}

void gtr_reveal_in_file_manager(std::string const& path)
{
    if (path.empty())
    {
        return;
    }

    if (try_reveal_with_file_manager_dbus(path))
    {
        return;
    }

    auto const file = Gio::File::create_for_path(path);
    if (Glib::file_test(path, Glib::FileTest::FILE_TEST_IS_DIR))
    {
        gtr_open_uri(file->get_uri());
    }
    else if (auto const parent = file->get_parent())
    {
        gtr_open_uri(parent->get_uri());
    }
}

bool gtr_try_open_uri(Glib::ustring const& uri)
{
    if (uri.empty())
    {
        return false;
    }

    bool opened = false;

    try
    {
        opened = Gio::AppInfo::launch_default_for_uri(uri);
    }
    catch (Glib::Error const&)
    {
    }

    if (!opened)
    {
        try
        {
            Glib::spawn_async({}, std::vector<std::string>{ "xdg-open", uri }, TR_GLIB_SPAWN_FLAGS(SEARCH_PATH));
            opened = true;
        }
        catch (Glib::SpawnError const&)
        {
        }
    }

    return opened;
}

void gtr_open_uri(Glib::ustring const& uri)
{
    if (!uri.empty() && !gtr_try_open_uri(uri))
    {
        gtr_message(fmt::format(fmt::runtime(_("Couldn't open '{url}'")), fmt::arg("url", uri)));
    }
}
