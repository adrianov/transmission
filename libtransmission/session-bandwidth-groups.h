// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

#pragma once

#include <string_view>

struct tr_session;

void tr_session_bandwidth_groups_read(tr_session* session, std::string_view config_dir);
void tr_session_bandwidth_groups_write(tr_session const* session, std::string_view config_dir);
