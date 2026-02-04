// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#pragma once

struct tr_session;

/** Pause all active downloads on volumes with free space below 1 GiB. */
void tr_session_pause_downloads_if_low_disk_space(tr_session* session);
