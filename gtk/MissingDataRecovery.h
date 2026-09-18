// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#include <glibmm/refptr.h>

class Session;

/// Recovery of torrents whose local data has gone missing (the "No data found!" local
/// error). GTK port of macOS `Controller+MissingDataLaunch`: try to recover by
/// re-pointing the torrent at a directory where its files exist, otherwise remove it
/// from the list while keeping the user's data.
namespace gtr_missing_data
{

/// On launch: for every torrent with a local error and no findable files, try to switch
/// it to a directory (drawn from the other torrents' download dirs) where all its files
/// exist, and remove the unrecoverable ones from the list. Torrents whose storage volume
/// is not currently available are kept. Never changes a torrent's paused/running state.
/// The scan runs on the session thread via a worker thread and rate-limits itself; the
/// call itself returns immediately.
void recover_or_remove_on_launch(Glib::RefPtr<Session> const& core);

/// Periodic: re-point torrents in local-error state whose data has become accessible in
/// one of the candidate download dirs. Never removes torrents and never changes
/// paused/running state. Cheap no-op when no torrent is errored.
void relocate_errored_torrents_if_accessible(Glib::RefPtr<Session> const& core);

} // namespace gtr_missing_data
