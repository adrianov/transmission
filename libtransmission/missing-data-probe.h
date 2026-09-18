// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Filesystem probing for missing-data recovery. The input is copied paths only — no
// locks, no tr_torrent — so this code is safe to run on a worker thread while the
// session thread keeps working. Probes distinguish three outcomes: a file is present
// (including its partial `".part"`), provably absent, or unknowable (I/O or permission
// error). Unknowable results are propagated conservatively: recovery keeps the torrent.
//
// Directories are summarised per torrent: all files present (Complete), some present
// (Partial), none present (Absent), or at least one probe failed (Unknown).

#pragma once

#include <optional>
#include <string>
#include <unordered_set>
#include <vector>

namespace missing_data_probe
{

/// Aggregate probe verdict for every torrent file inside one directory.
enum class DirState
{
    Absent, ///< probed successfully; no file is there
    Partial, ///< some (but not all) files are there
    Complete, ///< every file is there
    Unknown ///< at least one probe failed: state unknowable
};

/// What probing found for one torrent across the current directory and all candidates.
struct ProbeResult
{
    DirState cur; ///< current directory state
    std::optional<std::string> candidate; ///< a candidate directory holding every file
    bool some_data_elsewhere = false; ///< a candidate directory holds some files
    bool unknown_elsewhere = false; ///< a candidate directory could not be inspected
};

/// Probe `cur_dir` and every candidate directory (excluding `cur_dir` itself) for the
/// given torrent-relative file names.
[[nodiscard]] ProbeResult probe(
    std::vector<std::string> const& names,
    std::string const& cur_dir,
    std::unordered_set<std::string> const& candidate_dirs);

} // namespace missing_data_probe
