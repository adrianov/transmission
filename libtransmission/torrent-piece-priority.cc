// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <cctype>
#include <string>
#include <string_view>

#include "libtransmission/transmission.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrent-metainfo.h"
#include "libtransmission/tr-macros.h"
#include "libtransmission/utils.h"

using namespace std::literals;

void tr_torrent::update_piece_priority_state()
{
    bool has_audio = false;
    bool has_cover = false;
    for (tr_file_index_t i = 0, n = file_count(); i < n && (!has_audio || !has_cover); ++i)
    {
        auto const path = metainfo_.file_subpath(i);
        auto const path_sv = std::string_view{ path };
        auto const mime = tr_get_mime_type_for_filename(path);
        if (tr_strv_starts_with(mime, "audio/"sv))
        {
            has_audio = true;
        }
        else
        {
            auto const pos = path_sv.rfind('.');
            if (pos != std::string_view::npos && pos + 1 < path_sv.size())
            {
                auto ext = std::string{ path_sv.substr(pos + 1) };
                std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
                if (ext == "cue")
                {
                    has_audio = true;
                }
                else if (ext == "jpg" || ext == "jpeg")
                {
                    has_cover = true;
                }
            }
        }
    }
    has_audio_and_cover_ = has_audio && has_cover;
}

void tr_torrent::recalculate_file_order()
{
    // Get list of wanted files
    std::vector<tr_file_index_t> wanted_files;
    wanted_files.reserve(file_count());
    for (tr_file_index_t i = 0; i < file_count(); ++i)
    {
        if (files_wanted_.file_wanted(i))
        {
            wanted_files.push_back(i);
        }
    }

    // Sort wanted files alphabetically by path, but when one filename is a prefix
    // of another (with same extension), shorter comes first (e.g., "file.mkv" before "file.Bonus.mkv")
    auto const tolower_char = [](char c)
    {
        return std::tolower(static_cast<unsigned char>(c));
    };

    auto const compare_ci = [&tolower_char](std::string_view s1, std::string_view s2)
    {
        return std::lexicographical_compare(
            s1.begin(),
            s1.end(),
            s2.begin(),
            s2.end(),
            [&](char c1, char c2) { return tolower_char(c1) < tolower_char(c2); });
    };

    auto const equal_ci = [&tolower_char](std::string_view s1, std::string_view s2)
    {
        return s1.size() == s2.size() &&
            std::equal(
                   s1.begin(),
                   s1.end(),
                   s2.begin(),
                   [&](char c1, char c2) { return tolower_char(c1) == tolower_char(c2); });
    };

    std::sort(
        wanted_files.begin(),
        wanted_files.end(),
        [this, &compare_ci, &equal_ci](tr_file_index_t a, tr_file_index_t b)
        {
            auto const& path_a = files().path(a);
            auto const& path_b = files().path(b);

            // Split into directory and filename
            auto const split_path = [](std::string_view path)
            {
                auto const pos = path.rfind('/');
                return pos != std::string_view::npos ? std::make_pair(path.substr(0, pos), path.substr(pos + 1)) :
                                                       std::make_pair(std::string_view{}, path);
            };

            auto const [dir_a, name_a] = split_path(path_a);
            auto const [dir_b, name_b] = split_path(path_b);

            // Compare directories first
            if (!equal_ci(dir_a, dir_b))
            {
                return compare_ci(dir_a, dir_b);
            }

            // Split filename into base and extension
            auto const split_ext = [](std::string_view name)
            {
                auto const pos = name.rfind('.');
                return (pos != std::string_view::npos && pos > 0) ? std::make_pair(name.substr(0, pos), name.substr(pos)) :
                                                                    std::make_pair(name, std::string_view{});
            };

            auto const [base_a, ext_a] = split_ext(name_a);
            auto const [base_b, ext_b] = split_ext(name_b);

            // If same extension and one base is prefix of another, shorter wins
            if (equal_ci(ext_a, ext_b) && base_a.size() != base_b.size())
            {
                auto const& shorter = base_a.size() < base_b.size() ? base_a : base_b;
                auto const& longer = base_a.size() < base_b.size() ? base_b : base_a;
                if (equal_ci(shorter, longer.substr(0, shorter.size())))
                {
                    return base_a.size() < base_b.size();
                }
            }

            return compare_ci(name_a, name_b);
        });

    // Build mappings - initialize with a large value to indicate "not assigned"
    file_index_by_piece_.assign(piece_count(), piece_count());

    // Create a map from actual file index to alphabetical file index
    std::vector<tr_piece_index_t> file_idx_map(file_count(), piece_count());
    for (size_t file_idx = 0; file_idx < wanted_files.size(); ++file_idx)
    {
        auto const actual_file_index = wanted_files[file_idx];
        file_idx_map[actual_file_index] = static_cast<tr_piece_index_t>(file_idx);
    }

    // For each piece, find which files it belongs to and assign it to the first (alphabetically)
    for (tr_piece_index_t piece = 0; piece < piece_count(); ++piece)
    {
        if (!piece_is_wanted(piece))
        {
            continue;
        }

        auto const [file_begin, file_end] = fpm_.file_span_for_piece(piece);
        tr_piece_index_t best_file_idx = piece_count();

        // Find the first (alphabetically) wanted file that contains this piece
        for (tr_file_index_t file = file_begin; file < file_end; ++file)
        {
            if (files_wanted_.file_wanted(file))
            {
                auto const alphabetical_idx = file_idx_map[file];
                if (alphabetical_idx < best_file_idx)
                {
                    best_file_idx = alphabetical_idx;
                }
            }
        }

        if (best_file_idx < piece_count())
        {
            file_index_by_piece_[piece] = best_file_idx;
        }
    }
}

tr_piece_index_t tr_torrent::file_index_for_piece(tr_piece_index_t piece) const noexcept
{
    if (piece < file_index_by_piece_.size())
    {
        return file_index_by_piece_[piece];
    }
    return 0;
}

bool tr_torrent::is_video_file(tr_file_index_t file) const noexcept
{
    auto const mime_type = tr_get_mime_type_for_filename(metainfo_.file_subpath(file));
    if (tr_strv_starts_with(mime_type, "video/"sv))
    {
        return true;
    }

    // Fallback for common video extensions that might not be in the mime-type list
    // or might have different mime-types but still benefit from tail priority.
    auto const path = metainfo_.file_subpath(file);
    auto const path_sv = std::string_view{ path };
    auto const pos = path_sv.rfind('.');
    if (pos == std::string_view::npos || pos + 1 == path_sv.size())
    {
        return false;
    }

    auto ext = std::string{ path_sv.substr(pos + 1) };
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });

    // These formats often have important metadata at the end of the file (e.g. MOOV atom in MP4,
    // index in MKV/AVI) which is required for seeking or even starting playback.
    return ext == "avi" || ext == "mp4" || ext == "mkv" || ext == "mov" || ext == "m4v" || ext == "webm";
}

bool tr_torrent::is_piece_in_file_tail(tr_piece_index_t piece) const noexcept
{
    static constexpr uint64_t MaxTailSize = 20U * 1024U * 1024U; // 20 MB cap for very large files
    static constexpr uint64_t MinTailSize = 1024U * 1024U; // 1 MB minimum
    static constexpr double TailPercentage = 0.02; // 2% of file size

    auto const [file_begin, file_end] = fpm_.file_span_for_piece(piece);
    for (auto file = file_begin; file < file_end; ++file)
    {
        if (!files_wanted_.file_wanted(file) || !is_video_file(file))
        {
            continue;
        }

        auto const file_size = metainfo_.file_size(file);
        // Calculate proportional tail size: 2% of file, capped at 20 MB, minimum 1 MB
        auto const tail_size = std::min(MaxTailSize, std::max(MinTailSize, static_cast<uint64_t>(file_size * TailPercentage)));

        if (file_size <= tail_size)
        {
            // Small file - all pieces are in "tail"
            return true;
        }

        // Calculate byte offset of this piece within the file
        auto const byte_span = fpm_.byte_span_for_file(file);
        auto const piece_byte_begin = static_cast<uint64_t>(piece) * piece_size();
        auto const piece_byte_end = piece_byte_begin + piece_size(piece);

        // Check if piece overlaps with the tail portion of the file
        auto const tail_start = byte_span.end - tail_size;
        if (piece_byte_end > tail_start && piece_byte_begin < byte_span.end)
        {
            return true;
        }
    }
    return false;
}

bool tr_torrent::is_piece_in_priority_file(tr_piece_index_t piece) const noexcept
{
    // Priority file extensions for disc structures:
    // DVD: IFO (index), BUP (backup index)
    // Blu-ray: index.bdmv, MovieObject.bdmv
    auto const [file_begin, file_end] = fpm_.file_span_for_piece(piece);
    for (auto file = file_begin; file < file_end; ++file)
    {
        if (!files_wanted_.file_wanted(file))
        {
            continue;
        }

        auto const path = metainfo_.file_subpath(file);
        auto const path_sv = std::string_view{ path };

        // Check for DVD index files (.ifo, .bup - case insensitive)
        if (path_sv.size() >= 4)
        {
            auto ext = std::string{ path_sv.substr(path_sv.size() - 4) };
            std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
            if (ext == ".ifo" || ext == ".bup")
            {
                return true;
            }
        }

        // Check for Blu-ray index files (index.bdmv, movieobject.bdmv - case insensitive)
        if (path_sv.size() >= 10)
        {
            auto const slash_pos = path_sv.rfind('/');
            auto filename = std::string{ path_sv.substr(slash_pos == std::string_view::npos ? 0 : slash_pos + 1) };
            std::transform(filename.begin(), filename.end(), filename.begin(), [](unsigned char c) { return std::tolower(c); });
            if (filename == "index.bdmv" || filename == "movieobject.bdmv")
            {
                return true;
            }
        }

        // Audio torrents: prioritize .jpg/.jpeg (album cover) so cover art downloads first
        if (has_audio_and_cover_)
        {
            auto const pos = path_sv.rfind('.');
            if (pos != std::string_view::npos && pos + 1 < path_sv.size())
            {
                auto ext = std::string{ path_sv.substr(pos + 1) };
                std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
                if (ext == "jpg" || ext == "jpeg")
                {
                    return true;
                }
            }
        }
    }
    return false;
}
