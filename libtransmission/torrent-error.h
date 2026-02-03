// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#include <string>
#include <string_view>

#include "libtransmission/interned-string.h"
#include "libtransmission/transmission.h"

/** Tracks a torrent's error state: local (e.g. file IO) or tracker (e.g. warning/error). */
struct tr_torrent_error
{
    [[nodiscard]] constexpr auto empty() const noexcept
    {
        return error_type_ == TR_STAT_OK;
    }

    [[nodiscard]] constexpr auto error_type() const noexcept
    {
        return error_type_;
    }

    [[nodiscard]] constexpr auto const& announce_url() const noexcept
    {
        return announce_url_;
    }

    [[nodiscard]] constexpr auto const& errmsg() const noexcept
    {
        return errmsg_;
    }

    void set_tracker_warning(tr_interned_string announce_url, std::string_view errmsg);
    void set_tracker_error(tr_interned_string announce_url, std::string_view errmsg);
    void set_local_error(std::string_view errmsg);

    void clear() noexcept;
    void clear_if_tracker() noexcept;

private:
    tr_interned_string announce_url_;
    std::string errmsg_;
    tr_stat_errtype error_type_ = TR_STAT_OK;
};
