// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <string_view>

#include "libtransmission/torrent-error.h"

void tr_torrent_error::set_tracker_warning(tr_interned_string announce_url, std::string_view errmsg)
{
    announce_url_ = announce_url;
    errmsg_.assign(errmsg);
    error_type_ = TR_STAT_TRACKER_WARNING;
}

void tr_torrent_error::set_tracker_error(tr_interned_string announce_url, std::string_view errmsg)
{
    announce_url_ = announce_url;
    errmsg_.assign(errmsg);
    error_type_ = TR_STAT_TRACKER_ERROR;
}

void tr_torrent_error::set_local_error(std::string_view errmsg)
{
    announce_url_.clear();
    errmsg_.assign(errmsg);
    error_type_ = TR_STAT_LOCAL_ERROR;
}

void tr_torrent_error::clear() noexcept
{
    announce_url_.clear();
    errmsg_.clear();
    error_type_ = TR_STAT_OK;
}

void tr_torrent_error::clear_if_tracker() noexcept
{
    if (error_type_ == TR_STAT_TRACKER_WARNING || error_type_ == TR_STAT_TRACKER_ERROR)
    {
        clear();
    }
}
