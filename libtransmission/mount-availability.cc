// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Volume-availability probing for missing-data recovery. A directory is "detached" when
// it no longer exists (any platform) or when its volume is not provably mounted: a
// configured (/etc/fstab) mount point that is not currently mounted, or a
// removable-media location that is not currently mounted (Linux), an unmounted
// /Volumes entry (macOS), or an absent drive letter (Windows). On some platforms
// mount-point directories survive unmounting, so an existing directory alone never
// proves availability. When the mount table cannot be read, availability is unknown and
// the directory counts as detached: recovery keeps the torrent.

#include "mount-availability.h"

#include <cctype>

#include <optional>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_set>

namespace mount_availability
{

namespace
{

/// Returns the character encoded by the octal escape at `path[i]` (e.g. `\040`), or -1
/// when `path[i]` does not start one.
int decode_octal_escape(std::string const& path, size_t i)
{
    if (i + 3 >= path.size() || path[i] != '\\')
    {
        return -1;
    }

    auto value = 0;
    for (auto off = 1; off <= 3; ++off)
    {
        auto const digit = path[i + off];
        if (digit < '0' || digit > '7')
        {
            return -1;
        }

        value = value * 8 + (digit - '0');
    }

    return value;
}

/// Decodes the octal escapes (`\040` space, `\011` tab, `\012` newline, `\134` backslash,
/// …) the kernel uses in /proc/mounts paths, so targets with spaces compare equal to
/// their real directory names.
std::string decode_mount_path(std::string const& path)
{
    auto out = std::string{};
    out.reserve(path.size());

    for (size_t i = 0; i < path.size();)
    {
        if (auto const ch = decode_octal_escape(path, i); ch >= 0)
        {
            out.push_back(static_cast<char>(ch));
            i += 4;
        }
        else
        {
            out.push_back(path[i++]);
        }
    }

    return out;
}

/// Second whitespace-separated field of each meaningful line (`mount point`).
std::unordered_set<std::string> parse_mount_points(char const* path)
{
    auto points = std::unordered_set<std::string>{};

    auto file = std::ifstream{ path };
    if (!file.is_open())
    {
        return points;
    }

    for (std::string line; std::getline(file, line);)
    {
        if (line.empty() || line.front() == '#')
        {
            continue;
        }

        auto fields = std::istringstream{ line };
        auto spec = std::string{};
        auto target = std::string{};
        if (fields >> spec >> target)
        {
            points.insert(decode_mount_path(target));
        }
    }

    return points;
}

bool is_within(std::string const& dir, std::string const& mount_point)
{
    return dir.compare(0, mount_point.size(), mount_point) == 0 &&
        (dir.size() == mount_point.size() || dir[mount_point.size()] == '/');
}

// Platform-specific mount-table and detached-volume logic. A directory counts as
// detached (recovery keeps the torrent) when its volume is not provably available; the
// conservative rule is that unknown storage is detached.

} // namespace

#if defined(_WIN32)

#include <windows.h>

#elif defined(__APPLE__) || defined(__BSD__)

#include <sys/mount.h>
#include <sys/param.h>

MountTable read_mount_table()
{
    auto mounted = std::unordered_set<std::string>{};
    auto readable = false;

    // BSD/macOS: the kernel's live mount list, no /proc equivalent.
    auto* entries = static_cast<struct statfs*>(nullptr);
    if (int const n = getmntinfo(&entries, MNT_NOWAIT); n >= 0)
    {
        readable = true;
        for (int i = 0; i < n; ++i)
        {
            mounted.insert(entries[i].f_mntonname);
        }
    }

    return { std::move(mounted), parse_mount_points("/etc/fstab"), readable };
}

#else // Linux and other Unix with /proc

MountTable read_mount_table()
{
    auto mounted = parse_mount_points("/proc/mounts");
    auto const readable = !mounted.empty();
    return { std::move(mounted), parse_mount_points("/etc/fstab"), readable };
}

#endif

namespace
{

/// Removable-media root containing `dir`, if any (Linux-style layout).
std::optional<std::string_view> media_root_of(std::string const& dir)
{
    if (is_within(dir, "/media"))
    {
        return "/media";
    }
    if (is_within(dir, "/run/media"))
    {
        return "/run/media";
    }
    if (is_within(dir, "/mnt"))
    {
        return "/mnt";
    }
    return std::nullopt;
}

/// True when a real volume mount — the directory itself, or a mount strictly below the
/// containing media root — covers `dir`. Infrastructure ancestors (e.g. /run tmpfs)
/// say nothing about the removable volume and are not counted.
bool covered_by_real_mount(std::string const& dir, MountTable const& mounts, size_t root_size)
{
    for (auto const& mount_point : mounts.mounted)
    {
        if (mount_point == dir || (mount_point.size() > root_size && is_within(dir, mount_point)))
        {
            return true;
        }
    }

    return false;
}

/// Surviving mount-point directory of an fstab-less (e.g. udisks-automounted) volume:
/// under a removable-media location with no active mount covering it.
bool is_media_survivor(std::string const& dir, MountTable const& mounts)
{
#if defined(_WIN32)

    return false; // availability is decided by the drive-letter check

#elif defined(__APPLE__)

    return is_within(dir, "/Volumes") && !covered_by_real_mount(dir, mounts, std::size("/Volumes") - 1);

#else

    auto const root = media_root_of(dir);
    return root.has_value() && !covered_by_real_mount(dir, mounts, root->size());

#endif
}

/// Windows: a directory's volume is its drive letter; detached when that drive is not
/// currently present. UNC paths have no drive letter; reaching them here means the
/// filesystem probes over the same path succeeded, so the storage is reachable.
#if defined(_WIN32)
bool drive_is_missing(std::string const& dir, MountTable const& mounts)
{
    if (dir.size() < 2 || dir[1] != ':')
    {
        return false;
    }

    auto const drive = std::string{ 1, static_cast<char>(toupper(static_cast<unsigned char>(dir[0]))) } + ":\\";
    return mounts.mounted.count(drive) == 0;
}

#endif

} // namespace

bool is_on_detached_volume(std::string const& dir, MountTable const& mounts)
{
    if (dir.empty() || !mounts.readable)
    {
        return true; // unknown: keep
    }

    auto ec = std::error_code{};
    if (!std::filesystem::is_directory(std::filesystem::path{ dir }, ec))
    {
        return true; // provably gone: keep
    }

#if defined(_WIN32)

    return drive_is_missing(dir, mounts);

#else

    for (auto const& mount_point : mounts.configured)
    {
        if (is_within(dir, mount_point) && mounts.mounted.count(mount_point) == 0)
        {
            return true; // configured volume not mounted: keep
        }
    }

    if (is_media_survivor(dir, mounts))
    {
        return true;
    }

#endif

    return false;
}

} // namespace mount_availability
