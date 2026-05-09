// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <ios>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility> // std::move
#include <vector>

#include <fmt/format.h>

#include "libtransmission/transmission.h"

#include "libtransmission/crypto-utils.h" // for tr_sha1()
#include "libtransmission/error.h"
#include "libtransmission/file.h"
#include "libtransmission/quark.h"
#include "libtransmission/torrent-magnet.h"
#include "libtransmission/torrent-metainfo.h"
#include "libtransmission/torrent.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/utils.h"
#include "libtransmission/variant.h"

#define tr_logStderrMagnet(magnet, msg) tr_logStderr((magnet)->log_name(), (msg))

namespace
{
template<typename T>
[[nodiscard]] constexpr T n_metadata_pieces(T const& numerator) noexcept
{
    auto const quot = numerator / MetadataPieceSize;
    auto const rem = numerator % MetadataPieceSize;
    return quot + (rem == 0 ? 0 : 1);
}

[[nodiscard]] constexpr size_t metadata_piece_byte_length(int64_t const total_bytes, int64_t const piece_index) noexcept
{
    auto const pc = n_metadata_pieces(total_bytes);
    return piece_index + 1 == pc ? static_cast<size_t>(total_bytes - piece_index * MetadataPieceSize) : MetadataPieceSize;
}
} // namespace

void tr_metadata_download::create_all_needed(int64_t n_pieces) noexcept
{
    pieces_needed_.clear();
    pieces_needed_.resize(n_pieces);

    for (int64_t i = 0; i < n_pieces; ++i)
    {
        pieces_needed_[i].piece = i;
    }
}

[[nodiscard]] bool tr_metadata_download::piece_is_still_needed(int64_t const piece) const noexcept
{
    return std::any_of(
        std::begin(pieces_needed_),
        std::end(pieces_needed_),
        [piece](metadata_node const& n) { return n.piece == piece; });
}

[[nodiscard]] bool tr_metadata_download::can_retune_to_size(int64_t const new_size) const noexcept
{
    if (!is_valid_metadata_size(new_size))
    {
        return false;
    }

    auto const old_size = advertised_info_length();
    if (new_size == old_size)
    {
        return true;
    }

    auto const old_pc = piece_count_;
    auto const new_pc = n_metadata_pieces(new_size);

    for (int64_t i = 0; i < old_pc; ++i)
    {
        if (piece_is_still_needed(i))
        {
            continue;
        }

        if (i >= new_pc)
        {
            return false;
        }

        if (metadata_piece_byte_length(old_size, i) != metadata_piece_byte_length(new_size, i))
        {
            return false;
        }
    }

    return true;
}

void tr_metadata_download::retune_to_size(int64_t const new_size) noexcept
{
    TR_ASSERT(can_retune_to_size(new_size));

    if (new_size == advertised_info_length())
    {
        return;
    }

    std::vector<int64_t> completed;
    auto const old_pc = piece_count_;
    completed.reserve(static_cast<size_t>(old_pc));
    for (int64_t i = 0; i < old_pc; ++i)
    {
        if (!piece_is_still_needed(i))
        {
            completed.push_back(i);
        }
    }

    metadata_.resize(static_cast<size_t>(new_size));
    piece_count_ = n_metadata_pieces(new_size);
    create_all_needed(piece_count_);

    for (auto const i : completed)
    {
        if (i >= piece_count_)
        {
            continue;
        }

        auto& needed = pieces_needed_;
        if (auto iter = std::find_if(
                std::begin(needed),
                std::end(needed),
                [i](metadata_node const& n) { return n.piece == i; });
            iter != std::end(needed))
        {
            needed.erase(iter);
        }
    }

    tr_logStderrMagnet(
        this,
        fmt::format(
            "Magnet metadata: retuned assembly to {} bytes ({} piece(s) still needed)",
            new_size,
            static_cast<int64_t>(std::size(pieces_needed_))));
}

tr_metadata_download::tr_metadata_download(std::string_view log_name, int64_t const size)
    : log_name_{ std::string{ log_name } }
{
    TR_ASSERT(is_valid_metadata_size(size));

    auto const n = n_metadata_pieces(size);
    piece_count_ = n;
    metadata_.resize(size);
    create_all_needed(n);
    tr_logStderrMagnet(this, fmt::format("Magnet metadata: collecting {} bytes ({} piece(s))", size, n));
}

void tr_torrent::maybe_start_metadata_transfer(int64_t const size) noexcept
{
    if (has_metainfo())
    {
        return;
    }

    if (!tr_metadata_download::is_valid_metadata_size(size))
    {
        TR_ASSERT(false);
        tr_logStderrTor(this, fmt::format("Magnet metadata: ignored invalid metadata_size {:d}", size));
        return;
    }

    if (metadata_download_ != nullptr)
    {
        if (metadata_download_->advertised_info_length() == size)
        {
            return;
        }

        // LTEP can report conflicting sizes across peers; replacing the buffer after we
        // have real ut_metadata pieces discards progress and often breaks the download.
        if (metadata_download_->has_any_piece())
        {
            if (metadata_download_->can_retune_to_size(size))
            {
                tr_logStderrTor(
                    this,
                    fmt::format(
                        "Magnet metadata: peer reports metadata_size {:d} (was {:d}); retuning compatible assembly",
                        size,
                        metadata_download_->advertised_info_length()));
                metadata_download_->retune_to_size(size);
            }
            else
            {
                tr_logStderrTor(
                    this,
                    fmt::format(
                        "Magnet metadata: ignoring metadata_size {:d} (have partial data for {:d} bytes; incompatible)",
                        size,
                        metadata_download_->advertised_info_length()));
            }
            return;
        }

        tr_logStderrTor(
            this,
            fmt::format(
                "Magnet metadata: metadata_size {:d} replaces {:d}; restarting assembly (no pieces stored yet)",
                size,
                metadata_download_->advertised_info_length()));

        metadata_download_.reset();
    }

    metadata_download_ = std::make_unique<tr_metadata_download>(name(), size);
}

[[nodiscard]] std::optional<tr_metadata_piece> tr_torrent::get_metadata_piece(int64_t const piece) const
{
    TR_ASSERT(piece >= 0);

    if (!has_metainfo())
    {
        return {};
    }

    auto const info_dict_size = this->info_dict_size();
    using size_type = std::remove_cv_t<decltype(info_dict_size)>;
    TR_ASSERT(info_dict_size > 0);
    if (auto const n_pieces = std::max(size_type{ 1 }, n_metadata_pieces(info_dict_size));
        piece < 0 || static_cast<size_type>(piece) >= n_pieces)
    {
        return {};
    }

    auto in = std::ifstream{ torrent_file(), std::ios_base::in | std::ios_base::binary };
    if (!in.is_open())
    {
        return {};
    }
    auto const offset_in_info_dict = piece * MetadataPieceSize;
    if (auto const offset_in_file = info_dict_offset() + offset_in_info_dict;
        !in.seekg(static_cast<std::streamoff>(offset_in_file)))
    {
        return {};
    }

    auto const piece_len = static_cast<size_type>(offset_in_info_dict) + MetadataPieceSize <= info_dict_size ?
        MetadataPieceSize :
        info_dict_size - offset_in_info_dict;
    if (auto ret = tr_metadata_piece(piece_len);
        in.read(reinterpret_cast<char*>(std::data(ret)), static_cast<std::streamsize>(std::size(ret))))
    {
        return ret;
    }

    return {};
}

bool tr_torrent::use_metainfo_from_file(tr_torrent_metainfo const* metainfo, char const* filename_in, tr_error* error)
{
    // add .torrent file
    if (!tr_sys_path_copy(filename_in, torrent_file().c_str(), error))
    {
        return false;
    }

    // remove .magnet file
    tr_sys_path_remove(magnet_file());

    // tor should keep this metainfo
    set_metainfo(*metainfo);

    metadata_download_.reset();

    return true;
}

// ---

namespace
{
namespace set_metadata_piece_helpers
{
tr_variant build_metainfo_except_info_dict(tr_torrent_metainfo const& tm)
{
    auto top = tr_variant::Map{ 8U };

    if (auto const& val = tm.comment(); !std::empty(val))
    {
        top.try_emplace(TR_KEY_comment, val);
    }

    if (auto const& val = tm.source(); !std::empty(val))
    {
        top.try_emplace(TR_KEY_source, val);
    }

    if (auto const& val = tm.creator(); !std::empty(val))
    {
        top.try_emplace(TR_KEY_created_by, val);
    }

    if (auto const val = tm.date_created(); val != 0)
    {
        top.try_emplace(TR_KEY_creation_date, val);
    }

    if (auto const& announce_list = tm.announce_list(); !std::empty(announce_list))
    {
        announce_list.add_to_map(top);
    }

    if (auto const n_webseeds = tm.webseed_count(); n_webseeds > 0U)
    {
        auto webseed_vec = tr_variant::Vector{};
        webseed_vec.reserve(n_webseeds);
        for (size_t i = 0U; i < n_webseeds; ++i)
        {
            webseed_vec.emplace_back(tm.webseed(i));
        }
        top.try_emplace(TR_KEY_url_list, std::move(webseed_vec));
    }

    return tr_variant{ std::move(top) };
}
} // namespace set_metadata_piece_helpers
} // namespace

[[nodiscard]] bool tr_torrent::use_new_metainfo(tr_error* error)
{
    using namespace set_metadata_piece_helpers;

    auto const& m = metadata_download_;
    TR_ASSERT(m);

    auto const raw_info = std::string_view{ std::data(m->get_metadata()), std::size(m->get_metadata()) };

    // test the info_dict checksum
    auto const assembled_digest = tr_sha1::digest(raw_info);
    if (assembled_digest != info_hash())
    {
        tr_logStderrTor(
            this,
            fmt::format(
                "Magnet metadata: SHA1 of assembled info dict ({:s}) does not match magnet info-hash ({:s}); "
                "assembled size {:d} bytes — discarding (likely wrong metadata_size or corrupt pieces)",
                tr_sha1_to_string(assembled_digest).sv(),
                tr_sha1_to_string(info_hash()).sv(),
                static_cast<int64_t>(std::size(raw_info))));
        return false;
    }

    // Embed raw peer bytes for `info` (do not re-bencode through tr_variant); round-trip can change
    // encoding and break metainfo parse even when the SHA1 still matches the assembled buffer.
    auto serde = tr_variant_serde::benc();
    auto top_var = build_metainfo_except_info_dict(metainfo());
    auto outer = serde.to_string(top_var);
    if (std::empty(outer) || outer.front() != 'd' || outer.back() != 'e')
    {
        tr_logStderrTor(
            this,
            fmt::format(
                "Magnet metadata: outer fields serialization invalid (len={}, first='{:c}' last='{:c}')",
                std::size(outer),
                std::empty(outer) ? '?' : outer.front(),
                std::empty(outer) ? '?' : outer.back()));
        if (error != nullptr)
        {
            error->set(EINVAL, "magnet outer metainfo bencode serialization failed");
        }
        return false;
    }

    outer.resize(std::size(outer) - 1U); // drop root's closing 'e'; append info + close root
    outer.append("4:info");
    outer.append(raw_info);
    outer.push_back('e');

    auto const& benc = outer;

    // does this synthetic torrent file parse?
    auto metainfo = tr_torrent_metainfo{};
    auto parse_err = tr_error{};
    if (!metainfo.parse_benc(benc, &parse_err))
    {
        tr_logStderrTor(
            this,
            fmt::format(
                "Magnet metadata: assembled .torrent failed parse_benc (info {:d} bytes, file {:d} bytes benc): {}",
                static_cast<int64_t>(std::size(raw_info)),
                static_cast<int64_t>(std::size(benc)),
                parse_err ? parse_err.message() : "unknown error"));
        if (error != nullptr)
        {
            *error = std::move(parse_err);
            if (!*error)
            {
                error->set(EINVAL, "merged metainfo parse_benc failed");
            }
        }
        return false;
    }

    // save it
    if (!tr_file_save(torrent_file(), benc, error))
    {
        return false;
    }

    // remove .magnet file
    tr_sys_path_remove(magnet_file());

    // tor should keep this metainfo
    set_metainfo(metainfo);

    tr_logStderrTor(
        this,
        fmt::format(
            "Magnet metadata: complete — info dict {:d} bytes, writing {}",
            metainfo.info_dict_size(),
            torrent_file()));
    return true;
}

void tr_torrent::on_have_all_metainfo()
{
    auto& m = metadata_download_;
    if (!m)
    {
        tr_logStderrTor(this, fmt::format("Magnet metadata: on_have_all_metainfo called but no download state (ignored)"));
        return;
    }

    if (auto error = tr_error{}; !use_new_metainfo(&error)) /* drat. */
    {
        auto msg = std::string_view{ error && !std::empty(error.message()) ? error.message() : "unknown error" };
        tr_logStderrTor(
            this,
            fmt::format("Couldn't parse magnet metainfo: '{error}'. Redownloading metadata", fmt::arg("error", msg)));
    }

    m.reset();
}

bool tr_metadata_download::set_metadata_piece(int64_t const piece, void const* const data, size_t const len)
{
    TR_ASSERT(data != nullptr);

    // sanity test: is `piece` in range?
    if (piece < 0 || piece >= piece_count_)
    {
        tr_logStderrMagnet(
            this,
            fmt::format(
                "Rejected metadata piece {:d}: out of range (piece_count={:d})",
                piece,
                piece_count_));
        return false;
    }

    // sanity test: is `len` the right size?
    if (auto const expected = get_piece_length(piece); expected != len)
    {
        tr_logStderrMagnet(
            this,
            fmt::format(
                "Rejected metadata piece {:d}: length {:d} != expected {:d} (advertised total {:d} bytes)",
                piece,
                static_cast<int64_t>(len),
                static_cast<int64_t>(expected),
                advertised_info_length()));
        return false;
    }

    // do we need this piece?
    auto& needed = pieces_needed_;
    auto const iter = std::find_if(
        std::begin(needed),
        std::end(needed),
        [piece](auto const& item) { return item.piece == piece; });
    if (iter == std::end(needed))
    {
        tr_logStderrMagnet(this, fmt::format("Rejected metadata piece {:d}: already have it (duplicate)", piece));
        return false;
    }

    auto const offset = piece * MetadataPieceSize;
    std::copy_n(reinterpret_cast<char const*>(data), len, std::begin(metadata_) + offset);

    needed.erase(iter);

    return std::empty(needed);
}

void tr_torrent::set_metadata_piece(int64_t const piece, void const* const data, size_t const len)
{
    TR_ASSERT(data != nullptr);

    if (metadata_download_ == nullptr)
    {
        tr_logStderrTor(
            this,
            fmt::format(
                "Magnet metadata: received piece but metadata download not started (no metadata_size from peers yet?)"));
        return;
    }

    if (auto& m = metadata_download_; m && m->set_metadata_piece(piece, data, len))
    {
        // Why queue this invocation in session thread:
        // https://github.com/transmission/transmission/pull/6383#discussion_r1429202253
        session->queue_session_thread(
            [s = session, id = id()]
            {
                if (auto* tor = s->torrents().get(id); tor != nullptr)
                {
                    tor->on_have_all_metainfo();
                }
            });
    }
}

// ---

[[nodiscard]] std::optional<int64_t> tr_metadata_download::get_next_metadata_request(time_t const now) noexcept
{
    auto& needed = pieces_needed_;
    if (std::empty(needed))
    {
        return {};
    }

    // Prefer the missing piece least recently requested so we round-robin when several
    // are outstanding. Throttling is per peer in peer-msgs so multiple peers can ask for
    // the same piece (a single peer may never answer; others might).
    auto const iter = std::min_element(
        std::begin(needed),
        std::end(needed),
        [](metadata_node const& a, metadata_node const& b) noexcept
        {
            return a.requested_at < b.requested_at ||
                (a.requested_at == b.requested_at && a.piece < b.piece);
        });
    iter->requested_at = now;
    return iter->piece;
}

[[nodiscard]] std::optional<int64_t> tr_torrent::get_next_metadata_request(time_t const now) noexcept
{
    if (auto& m = metadata_download_; m)
    {
        return m->get_next_metadata_request(now);
    }

    return {};
}

[[nodiscard]] double tr_metadata_download::get_metadata_percent() const noexcept
{
    if (auto const n = piece_count_; n != 0)
    {
        return static_cast<double>(n - std::size(pieces_needed_)) / static_cast<double>(n);
    }

    return 0.0;
}

[[nodiscard]] double tr_torrent::get_metadata_percent() const noexcept
{
    if (has_metainfo())
    {
        return 1.0;
    }

    if (auto const& m = metadata_download_; m)
    {
        return m->get_metadata_percent();
    }

    return 0.0;
}

// ---

std::string tr_torrentGetMagnetLink(tr_torrent const* tor)
{
    return tor->magnet();
}

size_t tr_torrentGetMagnetLinkToBuf(tr_torrent const* tor, char* buf, size_t buflen)
{
    return tr_strv_to_buf(tr_torrentGetMagnetLink(tor), buf, buflen);
}
