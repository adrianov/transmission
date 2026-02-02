// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#include <optional>

struct tr_torrent;

bool did_files_disappear(tr_torrent* tor, std::optional<bool> has_any_local_data = {});

bool set_local_error_if_files_disappeared(tr_torrent* tor, std::optional<bool> has_any_local_data = {});
