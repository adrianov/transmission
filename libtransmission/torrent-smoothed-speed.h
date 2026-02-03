// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#include <cstdint>

#include "libtransmission/values.h"

/** Smooths speed estimates to avoid temporary changes skewing ETA. */
struct tr_smoothed_speed
{
    using Speed = libtransmission::Values::Speed;

    constexpr auto update(uint64_t time_msec, Speed speed)
    {
        if (timestamp_msec_ + MaxAgeMSec <= time_msec)
        {
            timestamp_msec_ = time_msec;
            speed_ = speed;
        }
        else if (timestamp_msec_ + MinUpdateMSec <= time_msec)
        {
            timestamp_msec_ = time_msec;
            speed_ = (speed_ * 4U + speed) / 5U;
        }

        return speed_;
    }

private:
    static auto constexpr MaxAgeMSec = 4000U;
    static auto constexpr MinUpdateMSec = 800U;

    uint64_t timestamp_msec_ = {};
    Speed speed_;
};
