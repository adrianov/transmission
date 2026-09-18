// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Answers one question for missing-data recovery: does a directory sit on storage that
// is not currently available (a detached volume), or is availability unknown? Callers
// must keep the torrent in both cases. See mount-availability.cc for the platform rules.

#pragma once

#include <string>
#include <unordered_set>

namespace mount_availability
{

struct MountTable
{
    std::unordered_set<std::string> mounted; ///< active mount points (/proc/mounts)
    std::unordered_set<std::string> configured; ///< configured mount points (/etc/fstab)
    bool readable = false; ///< false when /proc/mounts cannot be read
};

[[nodiscard]] MountTable read_mount_table();

[[nodiscard]] bool is_on_detached_volume(std::string const& dir, MountTable const& mounts);

} // namespace mount_availability
