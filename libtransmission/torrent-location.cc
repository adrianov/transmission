// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <array>
#include <string_view>

#include "libtransmission/transmission.h"
#include "libtransmission/error.h"
#include "libtransmission/log.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrent-files.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-macros.h"

#include <fmt/format.h>

namespace
{
namespace location_helpers
{
size_t buildSearchPathArray(tr_torrent const* tor, std::string_view* paths)
{
    auto* walk = paths;

    if (auto const& path = tor->download_dir(); !std::empty(path))
    {
        *walk++ = path.sv();
    }

    if (auto const& path = tor->incomplete_dir(); !std::empty(path))
    {
        *walk++ = path.sv();
    }

    return walk - paths;
}
} // namespace location_helpers
} // namespace

void tr_torrent::set_location_in_session_thread(std::string_view const path, bool move_from_old_path, int volatile* setme_state)
{
    TR_ASSERT(session->am_in_session_thread());

    auto ok = true;
    if (move_from_old_path)
    {
        if (setme_state != nullptr)
        {
            *setme_state = TR_LOC_MOVING;
        }

        // ensure the files are all closed and idle before moving
        session->close_torrent_files(id());
        session->verify_remove(this);

        auto error = tr_error{};
        ok = files().move(current_dir(), path, name(), &error);
        if (error)
        {
            this->error().set_local_error(
                fmt::format(
                    fmt::runtime(_("Couldn't move '{old_path}' to '{path}': {error} ({error_code})")),
                    fmt::arg("old_path", current_dir()),
                    fmt::arg("path", path),
                    fmt::arg("error", error.message()),
                    fmt::arg("error_code", error.code())));
            tr_torrentStop(this);
        }
    }

    // tell the torrent where the files are
    if (ok)
    {
        set_download_dir(path);

        if (move_from_old_path)
        {
            incomplete_dir_.clear();
            current_dir_ = download_dir();
        }
    }

    if (setme_state != nullptr)
    {
        *setme_state = ok ? TR_LOC_DONE : TR_LOC_ERROR;
    }
}

void tr_torrent::set_location(std::string_view location, bool move_from_old_path, int volatile* setme_state)
{
    if (setme_state != nullptr)
    {
        *setme_state = TR_LOC_MOVING;
    }

    session->run_in_session_thread([this, loc = std::string(location), move_from_old_path, setme_state]()
                                   { set_location_in_session_thread(loc, move_from_old_path, setme_state); });
}

void tr_torrentSetLocation(tr_torrent* tor, char const* location, bool move_from_old_path, int volatile* setme_state)
{
    TR_ASSERT(tr_isTorrent(tor));
    TR_ASSERT(location != nullptr);
    TR_ASSERT(*location != '\0');

    tor->set_location(location, move_from_old_path, setme_state);
}

std::optional<tr_torrent_files::FoundFile> tr_torrent::find_file(tr_file_index_t file_index) const
{
    using namespace location_helpers;

    auto paths = std::array<std::string_view, 4>{};
    auto const n_paths = buildSearchPathArray(this, std::data(paths));
    return files().find(file_index, std::data(paths), n_paths);
}

bool tr_torrent::has_any_local_data() const
{
    using namespace location_helpers;

    auto paths = std::array<std::string_view, 4>{};
    auto const n_paths = buildSearchPathArray(this, std::data(paths));
    return files().has_any_local_data(std::data(paths), n_paths);
}

void tr_torrentSetDownloadDir(tr_torrent* tor, char const* path)
{
    TR_ASSERT(tr_isTorrent(tor));

    if (tor->download_dir_ != path)
    {
        tor->set_download_dir(path, true);
    }
}

char const* tr_torrentGetDownloadDir(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->download_dir().c_str();
}

char const* tr_torrentGetCurrentDir(tr_torrent const* tor)
{
    TR_ASSERT(tr_isTorrent(tor));

    return tor->current_dir().c_str();
}
