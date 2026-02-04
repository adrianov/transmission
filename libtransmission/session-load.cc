// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <future>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include <fmt/format.h>

#include "libtransmission/file.h"
#include "libtransmission/log.h"
#include "libtransmission/session.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/transmission.h"
#include "libtransmission/torrent-ctor.h"
#include "libtransmission/utils.h"

using namespace std::literals;

namespace
{
auto get_remaining_files(std::string_view folder, std::vector<std::string>& queue_order)
{
    auto files = tr_sys_dir_get_files(folder);
    auto ret = std::vector<std::string>{};
    ret.reserve(std::size(files));
    std::sort(std::begin(queue_order), std::end(queue_order));
    std::sort(std::begin(files), std::end(files));

    std::set_difference(
        std::begin(files),
        std::end(files),
        std::begin(queue_order),
        std::end(queue_order),
        std::back_inserter(ret));

    // Read .torrent first if somehow a .magnet of the same hash exists
    // Example of possible cause: https://github.com/transmission/transmission/issues/5007
    std::stable_partition(
        std::begin(ret),
        std::end(ret),
        [](std::string_view name) { return tr_strv_ends_with(name, ".torrent"sv); });

    return ret;
}

void session_load_torrents(tr_session* session, tr_ctor* ctor, std::promise<size_t>* loaded_promise)
{
    auto n_torrents = size_t{};
    auto const& folder = session->torrentDir();

    auto load_func = [&folder, &n_torrents, ctor, buf = std::vector<char>{}](std::string_view name) mutable
    {
        if (tr_strv_ends_with(name, ".torrent"sv))
        {
            auto const path = tr_pathbuf{ folder, '/', name };
            if (ctor->set_metainfo_from_file(path.sv()) && tr_torrentNew(ctor, nullptr) != nullptr)
                ++n_torrents;
        }
        else if (tr_strv_ends_with(name, ".magnet"sv))
        {
            auto const path = tr_pathbuf{ folder, '/', name };
            if (tr_file_read(path, buf) &&
                ctor->set_metainfo_from_magnet_link(std::string_view{ std::data(buf), std::size(buf) }, nullptr) &&
                tr_torrentNew(ctor, nullptr) != nullptr)
                ++n_torrents;
        }
    };

    auto queue_order = session->torrent_queue().from_file();
    for (auto const& filename : queue_order)
        load_func(filename);
    for (auto const& filename : get_remaining_files(folder, queue_order))
        load_func(filename);

    if (n_torrents != 0U)
    {
        tr_logAddInfo(
            fmt::format(
                fmt::runtime(tr_ngettext("Loaded {count} torrent", "Loaded {count} torrents", n_torrents)),
                fmt::arg("count", n_torrents)));
    }

    loaded_promise->set_value(n_torrents);
}
} // namespace

size_t tr_sessionLoadTorrents(tr_session* session, tr_ctor* ctor)
{
    auto loaded_promise = std::promise<size_t>{};
    auto loaded_future = loaded_promise.get_future();

    session->run_in_session_thread(session_load_torrents, session, ctor, &loaded_promise);
    loaded_future.wait();
    return loaded_future.get();
}

size_t tr_sessionGetAllTorrents(tr_session* session, tr_torrent** buf, size_t buflen)
{
    auto& torrents = session->torrents();
    auto const n = std::size(torrents);
    if (buflen >= n)
        std::copy_n(std::begin(torrents), n, buf);
    return n;
}
