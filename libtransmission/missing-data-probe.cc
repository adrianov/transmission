// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/missing-data-probe.h>

#include <filesystem>
#include <cstddef>

namespace missing_data_probe
{

namespace
{

/// Filesystem probe verdict for a torrent file inside a directory.
enum class Presence
{
    Absent, ///< probed successfully; nothing there
    Present, ///< the file (or its partial `".part"`) exists
    Unknown ///< the probe itself failed (I/O or permission error)
};

Presence probe_file(std::string const& dir, std::string const& name)
{
    auto const base = std::filesystem::path{ dir } / name;
    auto ec_file = std::error_code{};
    auto ec_part = std::error_code{};

    if (std::filesystem::exists(base, ec_file) || std::filesystem::exists(base.string() + ".part", ec_part))
    {
        return Presence::Present;
    }

    return (ec_file || ec_part) ? Presence::Unknown : Presence::Absent;
}

DirState probe_dir(std::vector<std::string> const& names, std::string const& dir)
{
    auto n_present = size_t{ 0 };
    auto n_unknown = size_t{ 0 };

    for (auto const& name : names)
    {
        switch (probe_file(dir, name))
        {
        case Presence::Present:
            ++n_present;
            break;
        case Presence::Unknown:
            ++n_unknown;
            break;
        case Presence::Absent:
            break;
        }
    }

    if (n_unknown > 0)
    {
        return DirState::Unknown;
    }
    if (n_present == names.size())
    {
        return DirState::Complete;
    }
    return n_present > 0 ? DirState::Partial : DirState::Absent;
}

} // namespace

ProbeResult probe(
    std::vector<std::string> const& names,
    std::string const& cur_dir,
    std::unordered_set<std::string> const& candidate_dirs)
{
    auto result = ProbeResult{};
    result.cur = probe_dir(names, cur_dir);

    for (auto const& dir : candidate_dirs)
    {
        if (dir == cur_dir)
        {
            continue;
        }

        switch (probe_dir(names, dir))
        {
        case DirState::Complete:
            if (!result.candidate)
            {
                result.candidate = dir;
            }
            result.some_data_elsewhere = true;
            break;
        case DirState::Partial:
            result.some_data_elsewhere = true;
            break;
        case DirState::Unknown:
            result.unknown_elsewhere = true;
            break;
        case DirState::Absent:
            break;
        }
    }

    return result;
}

} // namespace missing_data_probe
