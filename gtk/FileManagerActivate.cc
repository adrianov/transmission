// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "FileManagerActivate.h"

#include "GtkCompat.h"

#include <giomm/dbusconnection.h>
#include <giomm/file.h>
#include <glibmm/fileutils.h>
#include <glibmm/spawn.h>
#include <glibmm/ustring.h>

#include <gdk/gdk.h>
#include <gtk/gtk.h>

#if defined(GDK_WINDOWING_X11)
#if GTK_CHECK_VERSION(4, 0, 0)
#include <gdk/x11/gdkx.h>
#else
#include <gdk/gdkx.h>
#endif
#endif

#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace
{

Glib::ustring file_manager_startup_id()
{
    guint32 user_time = 0;

#if defined(GDK_WINDOWING_X11)
    if (auto* display = gdk_display_get_default(); display != nullptr && GDK_IS_X11_DISPLAY(display))
    {
        user_time = gdk_x11_display_get_user_time(display);
    }
#endif

#if !GTK_CHECK_VERSION(4, 0, 0)
    if (user_time == 0U)
    {
        user_time = gtk_get_current_event_time();
    }
#endif

    if (user_time == 0U)
    {
        return {};
    }

    return Glib::ustring::format("_TIME", user_time);
}

/** Title of the file-manager window ShowItems opens: the basename of the item's parent directory. */
Glib::ustring file_manager_window_title_for_path(std::string const& path)
{
    auto const file = Gio::File::create_for_path(path);
    if (auto const parent = file->get_parent())
    {
        return parent->get_basename();
    }

    return file->get_basename();
}

std::optional<Glib::ustring> dbus_get_name_owner(Gio::DBus::Connection& connection, Glib::ustring const& name)
{
    try
    {
        auto reply = connection.call_sync(
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            Glib::VariantContainerBase::create_tuple({ Glib::Variant<Glib::ustring>::create(name) }),
            "org.freedesktop.DBus",
            1000);
        return Glib::VariantBase::cast_dynamic<Glib::Variant<Glib::ustring>>(reply.get_child(0)).get();
    }
    catch (Glib::Error const&)
    {
        return std::nullopt;
    }
}

#if defined(GDK_WINDOWING_X11)
Glib::ustring trim_leading_whitespace(std::string const& text)
{
    auto pos = text.find_first_not_of(" \t");
    return pos == std::string::npos ? Glib::ustring{} : Glib::ustring(text.substr(pos));
}

void try_raise_file_manager_window(Gio::DBus::Connection& connection, Glib::ustring const& expected_title)
{
    if (expected_title.empty())
    {
        return;
    }

    auto const fm_owner = dbus_get_name_owner(connection, "org.freedesktop.FileManager1");
    if (!fm_owner)
    {
        return;
    }

    guint32 pid = 0;
    try
    {
        auto reply = connection.call_sync(
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetConnectionUnixProcessID",
            Glib::VariantContainerBase::create_tuple({ Glib::Variant<Glib::ustring>::create(*fm_owner) }),
            "org.freedesktop.DBus",
            1000);
        pid = Glib::VariantBase::cast_dynamic<Glib::Variant<guint32>>(reply.get_child(0)).get();
    }
    catch (Glib::Error const&)
    {
        return;
    }

    if (pid == 0U)
    {
        return;
    }

    std::string output;
    try
    {
        int exit_status = 0;
        Glib::spawn_sync(
            "",
            std::vector<std::string>{ "wmctrl", "-lp" },
            TR_GLIB_SPAWN_FLAGS(SEARCH_PATH),
            {},
            &output,
            nullptr,
            &exit_status);
        if (exit_status != 0)
        {
            return;
        }
    }
    catch (Glib::SpawnError const&)
    {
        return;
    }

    Glib::ustring window_id;
    std::istringstream stream(output);
    for (std::string line; std::getline(stream, line);)
    {
        std::istringstream line_stream(line);
        Glib::ustring candidate_id;
        unsigned long desktop = 0;
        unsigned long line_pid = 0;
        Glib::ustring hostname;
        line_stream >> candidate_id >> desktop >> line_pid >> hostname;
        if (line_pid != pid)
        {
            continue;
        }

        Glib::ustring title;
        std::string title_buf;
        std::getline(line_stream, title_buf);
        title = trim_leading_whitespace(title_buf);
        if (title != expected_title)
        {
            continue;
        }

        window_id = candidate_id;
        break;
    }

    if (window_id.empty())
    {
        return;
    }

    try
    {
        Glib::spawn_async({}, std::vector<std::string>{ "wmctrl", "-ia", window_id.raw() }, TR_GLIB_SPAWN_FLAGS(SEARCH_PATH));
    }
    catch (Glib::SpawnError const&)
    {
    }
}
#endif

} // namespace

bool gtr_try_reveal_with_file_manager_dbus(std::string const& path)
{
    try
    {
        auto const connection = Gio::DBus::Connection::get_sync(TR_GIO_DBUS_BUS_TYPE(SESSION));
        auto const file = Gio::File::create_for_path(path);
        std::vector<Glib::ustring> const uris = { file->get_uri() };
        auto const startup_id = file_manager_startup_id();
        connection->call_sync(
            "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1",
            "ShowItems",
            Glib::VariantContainerBase::create_tuple({
                Glib::Variant<std::vector<Glib::ustring>>::create(uris),
                Glib::Variant<Glib::ustring>::create(startup_id),
            }),
            "org.freedesktop.FileManager1",
            1000);
#if defined(GDK_WINDOWING_X11)
        try_raise_file_manager_window(*connection, file_manager_window_title_for_path(path));
#endif
        return true;
    }
    catch (Glib::Error const&)
    {
        return false;
    }
}
