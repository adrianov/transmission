// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <string_view>

#include <fmt/format.h>

#include "libtransmission/utils.h"
#include "libtransmission/web-utils.h"

using namespace std::literals;

namespace
{

[[nodiscard]] constexpr auto toLowerAscii(unsigned char const ch) noexcept
{
    return (ch >= 'A' && ch <= 'Z') ? static_cast<char>(ch - 'A' + 'a') : static_cast<char>(ch);
}

[[nodiscard]] size_t find_ic(std::string_view const hay, std::string_view const needle, size_t pos = 0)
{
    if (std::empty(needle) || pos > std::size(hay))
    {
        return std::string_view::npos;
    }

    for (auto i = pos; i + std::size(needle) <= std::size(hay); ++i)
    {
        bool ok = true;
        for (size_t j = 0; j < std::size(needle); ++j)
        {
            if (toLowerAscii(static_cast<unsigned char>(hay[i + j])) != toLowerAscii(static_cast<unsigned char>(needle[j])))
            {
                ok = false;
                break;
            }
        }
        if (ok)
        {
            return i;
        }
    }

    return std::string_view::npos;
}

[[nodiscard]] std::string stripTags(std::string_view const in)
{
    std::string out;
    out.reserve(std::min(std::size(in), size_t{ 262144 }));
    bool in_tag = false;
    for (unsigned char const uch : in)
    {
        auto const c = static_cast<char>(uch);
        if (c == '<') { in_tag = true; }
        else if (c == '>') { in_tag = false; }
        else if (!in_tag) { out += c; }
    }
    return out;
}

void appendUtf8(std::string& out, uint32_t cp)
{
    if (cp < 0x80)
    {
        out += static_cast<char>(cp);
    }
    else if (cp < 0x800)
    {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x110000)
    {
        out += static_cast<char>(0xF0 | (cp >> 18));
        out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
    else
    {
        out += '?';
    }
}

[[nodiscard]] uint32_t decodeNamedEntity(std::string_view name)
{
    static auto constexpr Entities = std::array<std::pair<std::string_view, uint32_t>, 29>{ {
        { "amp"sv, '&' },      { "apos"sv, '\'' },   { "bull"sv, 0x2022 },
        { "cent"sv, 0xA2 },    { "copy"sv, 0xA9 },   { "deg"sv, 0xB0 },
        { "divide"sv, 0xF7 },  { "euro"sv, 0x20AC }, { "gt"sv, '>' },
        { "hellip"sv, 0x2026 },{ "laquo"sv, 0xAB },  { "ldquo"sv, 0x201C },
        { "lsquo"sv, 0x2018 }, { "lt"sv, '<' },      { "mdash"sv, 0x2014 },
        { "ndash"sv, 0x2013 }, { "nbsp"sv, ' ' },    { "para"sv, 0xB6 },
        { "plusmn"sv, 0xB1 },  { "pound"sv, 0xA3 },  { "quot"sv, '"' },
        { "raquo"sv, 0xBB },   { "rdquo"sv, 0x201D },{ "reg"sv, 0xAE },
        { "rsquo"sv, 0x2019 }, { "sect"sv, 0xA7 },   { "times"sv, 0xD7 },
        { "trade"sv, 0x2122 }, { "yen"sv, 0xA5 },
    } };

    auto const it = std::lower_bound(
        std::begin(Entities), std::end(Entities), name,
        [](auto const& lhs, auto const& rhs) { return lhs.first < rhs; });
    return it != std::end(Entities) && it->first == name ? it->second : 0;
}

[[nodiscard]] std::string decodeHtmlEntities(std::string_view in)
{
    auto out = std::string{};
    out.reserve(std::size(in));
    size_t i = 0;

    while (i < std::size(in))
    {
        if (in[i] != '&')
        {
            out += in[i++];
            continue;
        }

        auto const semi = in.find(';', i + 2);
        if (semi == std::string_view::npos || semi - i > 10)
        {
            out += in[i++];
            continue;
        }

        auto const name = in.substr(i + 1, semi - i - 1);
        auto cp = uint32_t{};

        if (tr_strv_starts_with(name, "#x"sv) || tr_strv_starts_with(name, "#X"sv))
        {
            auto const hex = name.substr(2);
            if (!std::empty(hex))
            {
                cp = 0;
                for (auto c : hex)
                {
                    cp *= 16;
                    if (c >= '0' && c <= '9') { cp += c - '0'; }
                    else if (c >= 'a' && c <= 'f') { cp += c - 'a' + 10; }
                    else if (c >= 'A' && c <= 'F') { cp += c - 'A' + 10; }
                    else { cp = 0; break; }
                }
            }
        }
        else if (tr_strv_starts_with(name, "#"sv))
        {
            auto const dec = name.substr(1);
            if (!std::empty(dec))
            {
                cp = 0;
                for (auto c : dec)
                {
                    if (c >= '0' && c <= '9') { cp = cp * 10 + (c - '0'); }
                    else { cp = 0; break; }
                }
            }
        }
        else
        {
            cp = decodeNamedEntity(name);
        }

        if (cp > 0)
        {
            appendUtf8(out, cp);
            i = semi + 1;
        }
        else
        {
            out += in[i++];
        }
    }

    return out;
}

[[nodiscard]] bool responseBodyLooksTextual(std::string_view const body)
{
    if (std::empty(body))
    {
        return false;
    }

    auto const n = std::min(std::size(body), size_t{ 512 });
    size_t good = 0;
    for (size_t i = 0; i < n; ++i)
    {
        auto const c = static_cast<unsigned char>(body[i]);
        if (c == '\n' || c == '\r' || c == '\t' || (c >= 32 && c != 127))
        {
            ++good;
        }
    }

    return good * 5 >= n * 2;
}

[[nodiscard]] std::string collapseWs(std::string_view s)
{
    std::string out;
    out.reserve(std::min(std::size(s), size_t{ 262144 }));
    bool space = false;
    for (auto const uch : s)
    {
        auto const c = static_cast<unsigned char>(uch);
        if (c == '\n' || c == '\r' || c == '\t' || c == ' ')
        {
            if (!space && !std::empty(out)) { out += ' '; space = true; }
        }
        else if (c >= 32 && c != 127) { out += static_cast<char>(c); space = false; }
    }
    while (!std::empty(out) && out.back() == ' ') { out.pop_back(); }
    return out;
}

void removeCiBlocks(std::string& html, std::string_view const open, std::string_view const close)
{
    while (true)
    {
        auto const o = find_ic(html, open, 0);
        if (o == std::string_view::npos) { return; }

        auto const c = find_ic(html, close, o + std::size(open));
        if (c == std::string_view::npos) { html.erase(o); return; }

        html.erase(o, c + std::size(close) - o);
    }
}

void stripHtmlComments(std::string& html)
{
    while (true)
    {
        auto const o = html.find("<!--");
        if (o == std::string::npos) { return; }

        auto const c = html.find("-->", o + 4);
        if (c == std::string::npos) { html.erase(o); return; }

        html.erase(o, c + 3 - o);
    }
}

[[nodiscard]] std::string truncateTrackerDetailText(std::string s)
{
    static auto constexpr MaxLen = size_t{ 256 };
    if (std::size(s) <= MaxLen)
    {
        return s;
    }

    auto constexpr Ellipsis = "..."sv;
    auto const cutoff = MaxLen - std::size(Ellipsis);
    s.resize(cutoff);

    if (auto const last_sp = s.find_last_of(' '); last_sp != std::string::npos && last_sp > cutoff / 2U)
    {
        s.resize(last_sp);
    }

    s += Ellipsis;
    return s;
}

[[nodiscard]] std::string httpErrorBodyExcerpt(std::string_view body)
{
    if (!responseBodyLooksTextual(body))
    {
        return {};
    }

    static auto constexpr ScanMax = size_t{ 262144 };
    auto work = std::string{ body.substr(0, std::min(std::size(body), ScanMax)) };

    removeCiBlocks(work, "<script"sv, "</script>"sv);
    removeCiBlocks(work, "<style"sv, "</style>"sv);
    stripHtmlComments(work);

    auto plain = collapseWs(decodeHtmlEntities(stripTags(work)));
    if (std::empty(plain))
    {
        return {};
    }

    return truncateTrackerDetailText(std::move(plain));
}

} // namespace

std::string tr_webFormatTrackerHttpError(long const response_code, std::string_view const response_body)
{
    auto const* const label = tr_webGetResponseStr(response_code);
    auto const excerpt = httpErrorBodyExcerpt(response_body);

    if (std::empty(excerpt))
    {
        return fmt::format("Tracker HTTP response {:d} ({:s})", response_code, label);
    }

    if (std::string_view{ label } == "Unknown Error"sv)
    {
        return fmt::format("Tracker HTTP response {:d} - {:s}", response_code, excerpt);
    }

    return fmt::format("Tracker HTTP response {:d} ({:s}) - {:s}", response_code, label, excerpt);
}
