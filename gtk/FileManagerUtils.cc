// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "Utils.h"

#include "FileManagerActivate.h"
#include "GtkCompat.h"

#include <libtransmission/torrent-files.h>
#include <libtransmission/transmission.h>
#include <libtransmission/utils.h>

#include <giomm/appinfo.h>
#include <giomm/file.h>
#include <glibmm/fileutils.h>
#include <glibmm/i18n.h>
#include <glibmm/miscutils.h>
#include <glibmm/spawn.h>

#include <string>

namespace
{

std::string torrent_explorer_path(tr_torrent const* tor)
{
    if (tor == nullptr)
    {
        return {};
    }

    char const* const current_dir = tr_torrentGetCurrentDir(tor);
    if (current_dir == nullptr || current_dir[0] == '\0')
    {
        return {};
    }

    if (tr_torrentView(tor).is_folder)
    {
        return Glib::build_filename(current_dir, tr_torrentName(tor));
    }

    auto path = tr_torrentFindFile(tor, 0);
    if (path.empty())
    {
        if (auto const* const name = tr_torrentFile(tor, 0).name; name != nullptr)
        {
            path = Glib::build_filename(current_dir, name);
        }
    }

    return path;
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

    if (gtr_try_reveal_with_file_manager_dbus(path))
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

void gtr_open_torrent(tr_torrent const* tor)
{
    if (tor == nullptr)
    {
        return;
    }

    if (tr_torrentFileCount(tor) == 1)
    {
        auto path = tr_torrentFindFile(tor, 0);
        if (path.empty())
        {
            path = torrent_explorer_path(tor);
        }

        if (path.empty())
        {
            return;
        }

        auto const& file = tr_torrentFile(tor, 0);
        bool const complete = file.length > 0 && file.have >= file.length;
        bool const partial = tr_strv_ends_with(path, tr_torrent_files::PartialFileSuffix);

        if (complete && !partial && Glib::file_test(path, Glib::FileTest::FILE_TEST_IS_REGULAR))
        {
            if (!gtr_try_open_uri(Gio::File::create_for_path(path)->get_uri()))
            {
                gtr_reveal_in_file_manager(path);
            }
        }
        else
        {
            gtr_reveal_in_file_manager(path);
        }
    }
    else if (auto const path = torrent_explorer_path(tor); !path.empty())
    {
        gtr_reveal_in_file_manager(path);
    }
}
