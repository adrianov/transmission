// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#pragma once

#include <string_view>

// Case-insensitive natural (version) compare. Returns -1, 0, or 1.
[[nodiscard]] int tr_strverscasecmp(std::string_view a, std::string_view b) noexcept;

// Case-insensitive equality.
[[nodiscard]] bool tr_strequalcase(std::string_view a, std::string_view b) noexcept;

// Compare torrent file paths for piece download order (natural sort, bonus-file prefix rule).
[[nodiscard]] int tr_compare_paths_for_piece_priority(std::string_view path_a, std::string_view path_b) noexcept;
