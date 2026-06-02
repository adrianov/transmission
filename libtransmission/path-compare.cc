// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <cctype>
#include <string_view>
#include <utility>

#include "libtransmission/path-compare.h"

namespace
{

[[nodiscard]] constexpr char tolower_char(char c) noexcept
{
    return static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
}

[[nodiscard]] bool is_digit_char(char c) noexcept
{
    return std::isdigit(static_cast<unsigned char>(c)) != 0;
}

[[nodiscard]] std::pair<std::string_view, std::string_view> split_path(std::string_view path) noexcept
{
    auto const pos = path.rfind('/');
    return pos != std::string_view::npos ? std::make_pair(path.substr(0, pos), path.substr(pos + 1)) :
                                           std::make_pair(std::string_view{}, path);
}

[[nodiscard]] std::pair<std::string_view, std::string_view> split_ext(std::string_view name) noexcept
{
    auto const pos = name.rfind('.');
    return (pos != std::string_view::npos && pos > 0) ? std::make_pair(name.substr(0, pos), name.substr(pos)) :
                                                       std::make_pair(name, std::string_view{});
}

} // namespace

bool tr_strequalcase(std::string_view a, std::string_view b) noexcept
{
    return a.size() == b.size() &&
        std::equal(a.begin(), a.end(), b.begin(), [](char c1, char c2) { return tolower_char(c1) == tolower_char(c2); });
}

int tr_strverscasecmp(std::string_view a, std::string_view b) noexcept
{
    auto i = std::size_t{};
    auto j = std::size_t{};

    while (i < a.size() || j < b.size())
    {
        if (i >= a.size())
        {
            return -1;
        }

        if (j >= b.size())
        {
            return 1;
        }

        auto const c1 = tolower_char(a[i]);
        auto const c2 = tolower_char(b[j]);

        if (is_digit_char(c1) && is_digit_char(c2))
        {
            auto i_end = i;
            while (i_end < a.size() && is_digit_char(a[i_end]))
            {
                ++i_end;
            }

            auto j_end = j;
            while (j_end < b.size() && is_digit_char(b[j_end]))
            {
                ++j_end;
            }

            auto si = i;
            while (si < i_end && a[si] == '0')
            {
                ++si;
            }

            auto sj = j;
            while (sj < j_end && b[sj] == '0')
            {
                ++sj;
            }

            auto const rem_a = i_end - si;
            auto const rem_b = j_end - sj;

            if (rem_a != rem_b)
            {
                return rem_a < rem_b ? -1 : 1;
            }

            while (si < i_end)
            {
                auto const d1 = tolower_char(a[si]) - '0';
                auto const d2 = tolower_char(b[sj]) - '0';
                if (d1 != d2)
                {
                    return d1 < d2 ? -1 : 1;
                }

                ++si;
                ++sj;
            }

            if ((i_end - i) != (j_end - j))
            {
                return (i_end - i) < (j_end - j) ? -1 : 1;
            }

            i = i_end;
            j = j_end;
            continue;
        }

        if (c1 != c2)
        {
            return c1 < c2 ? -1 : 1;
        }

        ++i;
        ++j;
    }

    return 0;
}

int tr_compare_paths_for_piece_priority(std::string_view path_a, std::string_view path_b) noexcept
{
    auto const [dir_a, name_a] = split_path(path_a);
    auto const [dir_b, name_b] = split_path(path_b);

    if (!tr_strequalcase(dir_a, dir_b))
    {
        return tr_strverscasecmp(dir_a, dir_b);
    }

    auto const [base_a, ext_a] = split_ext(name_a);
    auto const [base_b, ext_b] = split_ext(name_b);

    // When one filename is a prefix of another (same extension), shorter comes first
    // (e.g., "file.mkv" before "file.Bonus.mkv").
    if (tr_strequalcase(ext_a, ext_b) && base_a.size() != base_b.size())
    {
        auto const& shorter = base_a.size() < base_b.size() ? base_a : base_b;
        auto const& longer = base_a.size() < base_b.size() ? base_b : base_a;
        if (tr_strequalcase(shorter, longer.substr(0, shorter.size())))
        {
            if (base_a.size() < base_b.size())
            {
                return -1;
            }

            if (base_a.size() > base_b.size())
            {
                return 1;
            }

            return 0;
        }
    }

    return tr_strverscasecmp(name_a, name_b);
}
