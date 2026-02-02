// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <string>
#include <string_view>

#include <fmt/format.h>

#include "libtransmission/transmission.h"
#include "libtransmission/announcer.h"
#include "libtransmission/error.h"
#include "libtransmission/log.h"
#include "libtransmission/peer-mgr.h"
#include "libtransmission/torrent.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-macros.h"
#include "libtransmission/utils.h"
#include "libtransmission/web-utils.h"

bool tr_torrent::set_announce_list(std::string_view announce_list_str)
{
    auto ann = tr_announce_list{};
    return ann.parse(announce_list_str) && set_announce_list(std::move(ann));
}

bool tr_torrent::set_announce_list(tr_announce_list announce_list)
{
    auto const lock = unique_lock();

    auto& tgt = metainfo_.announce_list();

    tgt = std::move(announce_list);

    auto save_error = tr_error{};
    auto filename = std::string{};
    if (has_metainfo())
    {
        filename = torrent_file();
        tgt.save(filename, &save_error);
    }
    else
    {
        filename = magnet_file();
        tr_file_save(filename, magnet(), &save_error);
    }

    on_announce_list_changed();

    if (save_error.has_value())
    {
        error().set_local_error(
            fmt::format(
                fmt::runtime(_("Couldn't save '{path}': {error} ({error_code})")),
                fmt::arg("path", filename),
                fmt::arg("error", save_error.message()),
                fmt::arg("error_code", save_error.code())));
        return false;
    }

    return true;
}

void tr_torrent::on_announce_list_changed()
{
    if (auto const& error_url = error_.announce_url(); !std::empty(error_url))
    {
        auto const& ann = metainfo().announce_list();
        if (std::none_of(
                std::begin(ann),
                std::end(ann),
                [error_url](auto const& tracker) { return tracker.announce == error_url; }))
        {
            error_.clear();
        }
    }

    mark_edited();

    session->announcer_->resetTorrent(this);
}

void tr_torrent::on_tracker_response(tr_tracker_event const* event)
{
    switch (event->type)
    {
    case tr_tracker_event::Type::Peers:
        tr_logAddTraceTor(this, fmt::format("Got {} peers from tracker", std::size(event->pex)));
        tr_peerMgrAddPex(this, TR_PEER_FROM_TRACKER, std::data(event->pex), std::size(event->pex));
        break;

    case tr_tracker_event::Type::Counts:
        if (is_private() && (event->leechers == 0 || event->downloaders == 0))
        {
            swarm_is_all_upload_only_.emit(this);
        }

        break;

    case tr_tracker_event::Type::Warning:
        tr_logAddWarnTor(
            this,
            fmt::format(
                fmt::runtime(_("Tracker warning: '{warning}' ({url})")),
                fmt::arg("warning", event->text),
                fmt::arg("url", tr_urlTrackerLogName(event->announce_url))));
        error_.set_tracker_warning(event->announce_url, event->text);
        break;

    case tr_tracker_event::Type::Error:
        error_.set_tracker_error(event->announce_url, event->text);
        break;

    case tr_tracker_event::Type::ErrorClear:
        error_.clear_if_tracker();
        break;
    }
}

bool tr_torrentSetTrackerList(tr_torrent* tor, char const* text)
{
    return text != nullptr && tor->set_announce_list(text);
}

std::string tr_torrentGetTrackerList(tr_torrent const* tor)
{
    return tor->announce_list().to_string();
}

size_t tr_torrentGetTrackerListToBuf(tr_torrent const* tor, char* buf, size_t buflen)
{
    return tr_strv_to_buf(tr_torrentGetTrackerList(tor), buf, buflen);
}
