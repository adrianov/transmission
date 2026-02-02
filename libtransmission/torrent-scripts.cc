// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <array>
#include <map>
#include <sstream>
#include <string>
#include <string_view>

#include <fmt/chrono.h>
#include <fmt/format.h>

#include "libtransmission/transmission.h"
#include "libtransmission/announcer.h"
#include "libtransmission/error.h"
#include "libtransmission/log.h"
#include "libtransmission/session.h"
#include "libtransmission/subprocess.h"
#include "libtransmission/torrent.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/utils.h"
#include "libtransmission/version.h"

#include "libtransmission/torrent-scripts.h"

using namespace std::literals;

namespace
{
namespace script_helpers
{
[[nodiscard]] std::string build_labels_string(tr_torrent::labels_t const& labels)
{
    auto buf = std::stringstream{};

    for (auto it = std::begin(labels), end = std::end(labels); it != end;)
    {
        buf << it->sv();

        if (++it != end)
        {
            buf << ',';
        }
    }

    return buf.str();
}

[[nodiscard]] std::string buildTrackersString(tr_torrent const* tor)
{
    auto buf = std::stringstream{};

    for (size_t i = 0, n = tr_torrentTrackerCount(tor); i < n; ++i)
    {
        buf << tr_torrentTracker(tor, i).host_and_port;

        if (i < n)
        {
            buf << ',';
        }
    }

    return buf.str();
}

void torrentCallScript(tr_torrent const* tor, std::string const& script)
{
    if (std::empty(script))
    {
        return;
    }

    auto const now = tr_time();

    auto torrent_dir = tr_pathbuf{ tor->current_dir() };
    tr_sys_path_native_separators(std::data(torrent_dir));

    auto const cmd = std::array<char const*, 2>{ script.c_str(), nullptr };

    auto const id_str = std::to_string(tr_torrentId(tor));
    auto const labels_str = build_labels_string(tor->labels());
    auto const trackers_str = buildTrackersString(tor);
    auto const bytes_downloaded_str = std::to_string(tor->bytes_downloaded_.ever());
    auto const localtime_str = fmt::format("{:%a %b %d %T %Y%n}", *std::localtime(&now));
    auto const priority_str = std::to_string(tor->get_priority());

    auto const env = std::map<std::string_view, std::string_view>{
        { "TR_APP_VERSION"sv, SHORT_VERSION_STRING },
        { "TR_TIME_LOCALTIME"sv, localtime_str },
        { "TR_TORRENT_BYTES_DOWNLOADED"sv, bytes_downloaded_str },
        { "TR_TORRENT_DIR"sv, torrent_dir.c_str() },
        { "TR_TORRENT_HASH"sv, tor->info_hash_string() },
        { "TR_TORRENT_ID"sv, id_str },
        { "TR_TORRENT_LABELS"sv, labels_str },
        { "TR_TORRENT_NAME"sv, tor->name() },
        { "TR_TORRENT_PRIORITY"sv, priority_str },
        { "TR_TORRENT_TRACKERS"sv, trackers_str },
    };

    tr_logAddInfoTor(tor, fmt::format(fmt::runtime(_("Calling script '{path}'")), fmt::arg("path", script)));

    auto error = tr_error{};
    if (!tr_spawn_async(std::data(cmd), env, TR_IF_WIN32("\\", "/"), &error))
    {
        tr_logAddWarnTor(
            tor,
            fmt::format(
                fmt::runtime(_("Couldn't call script '{path}': {error} ({error_code})")),
                fmt::arg("path", script),
                fmt::arg("error", error.message()),
                fmt::arg("error_code", error.code())));
    }
}
} // namespace script_helpers
} // namespace

void callScriptIfEnabled(tr_torrent const* tor, TrScript type)
{
    using namespace script_helpers;

    auto const* session = tor->session;

    if (tr_sessionIsScriptEnabled(session, type))
    {
        torrentCallScript(tor, session->script(type));
    }
}
