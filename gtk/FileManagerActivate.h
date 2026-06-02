// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#include <string>

/** Select @a path in the session file manager via D-Bus and raise its window (best effort). */
[[nodiscard]] bool gtr_try_reveal_with_file_manager_dbus(std::string const& path);
