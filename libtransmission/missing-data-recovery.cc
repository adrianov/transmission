// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Recovery for torrents whose files went missing ("No data found!" local error):
// re-point torrents whose files exist under another configured download directory,
// re-verify torrents whose files reappeared at the current location, and — when asked —
// remove torrents whose data is provably gone from available storage (files are kept).
//
// A recovery round runs as a session-owned asynchronous operation so that slow storage
// never stalls the session:
// 1. snapshot, on the session thread under the session lock: per-errored-torrent id,
//    current directory, and file names, plus every torrent's download directory;
// 2. probe, on a worker thread: pure filesystem checks over the copied paths — no lock,
//    no tr_torrent — so the session thread keeps processing network events, queued
//    operations, and shutdown while storage stalls;
// 3. apply, posted back to the session thread: the mount table is re-read fresh (a
//    volume unmounted during probing is honoured), every torrent is re-validated (still
//    present, same directory, still in the missing-data error), and results are applied
//    under the lock. The completion state is fulfilled only after application finishes.
// A relocation's status cell is a plain local `int volatile`: set_location runs inline
// on the session thread, so it is written and read on this same thread — never accessed
// across threads.
//
// Removal requires positive identification of missing data: the missing-data error
// text, previously verified data, no file found at the current location, in any
// candidate directory, or in the torrent's own search paths, and — per the fresh mount
// table — storage provably present. Unknowable probe results (I/O or permission
// errors) keep the torrent.
//
// Recovery never changes a torrent's paused/running state: a running torrent keeps
// running through a relocation, a paused one stays paused (a deliberate divergence from
// the macOS client, which restarts after a switch).

#include <libtransmission/transmission.h>

#include <libtransmission/missing-data-probe.h>
#include <libtransmission/mount-availability.h>
#include <libtransmission/session.h>
#include <libtransmission/torrent-helpers.h>
#include <libtransmission/torrent.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <future>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

namespace missing_data_recovery
{

namespace
{

/// One recovery round at a time, process-wide (this fork runs a single session). The
/// guard is retained until the apply step has completed, so a caller that observes
/// completion can safely start the next round.
std::atomic<bool> round_in_flight{ false };

/// True when the torrent is in exactly the condition this recovery promises to handle:
/// the "No data found!" local error over real metadata with real files.
bool in_missing_data_error(tr_torrent const* tor, tr_stat const* stat, std::string const& cur_dir)
{
    return stat->error == TR_STAT_LOCAL_ERROR && tr_torrentHasMetadata(tor) && tr_torrentFileCount(tor) > 0 &&
        stat->errorString != nullptr && !cur_dir.empty() && missing_data_error_text() == std::string_view{ stat->errorString };
}

/// One errored torrent's copied state: enough to probe the filesystem without the
/// session lock and without touching any tr_torrent.
struct RecoveryJob
{
    tr_torrent_id_t id;
    std::string cur_dir;
    std::vector<std::string> file_names;
};

std::vector<RecoveryJob> collect_jobs(tr_session* session)
{
    auto jobs = std::vector<RecoveryJob>{};

    for (auto* const tor : session->torrents())
    {
        auto const* const stat = tr_torrentStat(tor);
        auto const* const dir = tr_torrentGetCurrentDir(tor);
        if (dir == nullptr)
        {
            continue;
        }

        auto const cur_dir = std::string{ dir };
        if (!in_missing_data_error(tor, stat, cur_dir))
        {
            continue;
        }

        auto& job = jobs.emplace_back(RecoveryJob{ tr_torrentId(tor), cur_dir, {} });
        auto const n_files = tr_torrentFileCount(tor);
        job.file_names.reserve(n_files);
        for (tr_file_index_t i = 0; i < n_files; ++i)
        {
            job.file_names.emplace_back(tr_torrentFile(tor, i).name);
        }
    }

    return jobs;
}

std::unordered_set<std::string> collect_candidate_dirs(tr_session* session)
{
    auto dirs = std::unordered_set<std::string>{};
    for (auto* const tor : session->torrents())
    {
        auto const* const dir = tr_torrentGetDownloadDir(tor);
        if (dir != nullptr && *dir != '\0')
        {
            dirs.emplace(dir);
        }
    }
    return dirs;
}

/// Snapshot phase: copy the state needed for probing while the session thread is
/// serialized with the rest of libtransmission.
struct RecoveryState
{
    tr_session* session;
    bool remove_unrecoverable;
    std::vector<RecoveryJob> jobs;
    std::unordered_set<std::string> candidate_dirs;
    std::vector<missing_data_probe::ProbeResult> probes; ///< filled by the worker thread
    std::promise<uint32_t> done; ///< fulfilled after the apply step completes

    void snapshot()
    {
        candidate_dirs = collect_candidate_dirs(session);
        jobs = collect_jobs(session);
    }

    /// Probe phase: pure filesystem work on the worker thread — no lock, no tr_torrent.
    void probe()
    {
        probes.reserve(std::size(jobs));
        for (auto const& job : jobs)
        {
            probes.push_back(missing_data_probe::probe(job.file_names, job.cur_dir, candidate_dirs));
        }
    }
};

/// Re-validate a probed job at apply time: the torrent must still exist, still sit in
/// the probed directory, and still carry the missing-data error.
tr_torrent* revalidate_job(tr_session* session, RecoveryJob const& job)
{
    auto* tor = session->torrents().get(job.id);
    if (tor == nullptr)
    {
        return nullptr;
    }

    auto const* stat = tr_torrentStat(tor);
    auto const* const cur_dir = tr_torrentGetCurrentDir(tor);
    if (cur_dir == nullptr || job.cur_dir != cur_dir || !in_missing_data_error(tor, stat, job.cur_dir))
    {
        return nullptr;
    }

    return tor;
}

enum class Outcome
{
    None, ///< nothing to do (or nothing accessible yet)
    Changed, ///< re-verified or relocated successfully
    Removed ///< unrecoverable and removed from the list (data files kept)
};

/// Removal requires confirmed absence everywhere probed: no file at the current
/// location, in any candidate directory, or in the torrent's own search paths — and no
/// probe failure anywhere (unknowable storage keeps the torrent). Also requires
/// previously verified data (a never-downloaded torrent is not "missing") and — per the
/// mount table read fresh at apply time — provably present storage.
bool may_remove_unrecoverable(
    tr_torrent* tor,
    tr_stat const* stat,
    RecoveryJob const& job,
    missing_data_probe::ProbeResult const& probed,
    mount_availability::MountTable const& mounts,
    bool remove_unrecoverable)
{
    return remove_unrecoverable && stat->haveValid > 0 && probed.cur == missing_data_probe::DirState::Absent &&
        !probed.some_data_elsewhere && !probed.unknown_elsewhere && !tor->has_any_local_data() &&
        !mount_availability::is_on_detached_volume(job.cur_dir, mounts);
}

/// Apply one torrent's probe result. Must run on the session thread under the lock.
Outcome apply_probe(
    tr_session* session,
    tr_torrent* tor,
    RecoveryJob const& job,
    missing_data_probe::ProbeResult const& probed,
    mount_availability::MountTable const& mounts,
    bool remove_unrecoverable)
{
    auto const* stat = tr_torrentStat(tor);

    if (probed.cur == missing_data_probe::DirState::Complete)
    {
        if (stat->activity == TR_STATUS_CHECK || stat->activity == TR_STATUS_CHECK_WAIT)
        {
            return Outcome::None; // verify already queued or running
        }

        tr_torrentVerify(tor); // queued on the session thread
        session->rpcNotify(TR_RPC_TORRENT_CHANGED, tor);
        return Outcome::Changed;
    }

    if (probed.candidate)
    {
        // Local status cell: set_location runs inline on the session thread, so the
        // final state is written (and read here) on this same thread.
        int volatile status = TR_LOC_MOVING;
        tr_torrentSetLocation(tor, probed.candidate->c_str(), false, &status);

        if (status == TR_LOC_DONE)
        {
            session->rpcNotify(TR_RPC_TORRENT_MOVED, tor);
            return Outcome::Changed;
        }
        // A failed switch falls through to the removal check, as with the macOS client.
    }

    if (!may_remove_unrecoverable(tor, stat, job, probed, mounts, remove_unrecoverable))
    {
        return Outcome::None;
    }

    // Mirrors the torrent-remove RPC handler: let clients drop their rows first; they
    // may veto with TR_RPC_NOREMOVE.
    if ((session->rpcNotify(TR_RPC_TORRENT_REMOVING, tor) & TR_RPC_NOREMOVE) != 0)
    {
        return Outcome::None;
    }

    return Outcome::Removed;
}

/// Apply phase: re-validate each torrent, then apply its probe result. Torrents removed
/// here are collected in `removed` and freed by the caller after the loop.
uint32_t apply_all_jobs(
    tr_session* session,
    std::vector<RecoveryJob> const& jobs,
    std::vector<missing_data_probe::ProbeResult> const& probes,
    mount_availability::MountTable const& mounts,
    bool remove_unrecoverable,
    std::vector<tr_torrent*>& removed)
{
    auto changed = uint32_t{ 0 };
    for (size_t i = 0; i < std::size(jobs); ++i)
    {
        auto* tor = revalidate_job(session, jobs[i]);
        if (tor == nullptr)
        {
            continue;
        }

        switch (apply_probe(session, tor, jobs[i], probes[i], mounts, remove_unrecoverable))
        {
        case Outcome::None:
            break;
        case Outcome::Changed:
            ++changed;
            break;
        case Outcome::Removed:
            // tr_torrentRemove frees the torrent, so removal happens after this loop.
            ++changed;
            removed.push_back(tor);
            break;
        }
    }

    return changed;
}

/// Apply step, run on the session thread: the mount table is read fresh (a volume
/// unmounted during probing is honoured), every job is re-validated, and the returned
/// count is accurate only after everything is applied.
uint32_t apply_round_on_session_thread(std::shared_ptr<RecoveryState> state)
{
    auto lock = state->session->unique_lock();

    // Fresh availability evidence: the snapshot used for probing must not be treated as
    // current proof when authorizing removal.
    auto const mounts = mount_availability::read_mount_table();

    auto removed = std::vector<tr_torrent*>{};
    auto const
        changed = apply_all_jobs(state->session, state->jobs, state->probes, mounts, state->remove_unrecoverable, removed);

    for (auto* const tor : removed)
    {
        // Clients already dropped their rows (REMOVING notify); data files are kept.
        tr_torrentRemove(tor, false, nullptr, nullptr, nullptr, nullptr);
    }

    return changed;
}

/// Start a round: probe the snapshotted state on a worker thread, then apply back on
/// the session thread. The caller must have snapshotted `state` under the session lock.
void start_round(std::shared_ptr<RecoveryState> state)
{
    std::thread(
        [state]()
        {
            state->probe();

            // The session may have started closing while probing; a task posted after
            // the close tasks would run mid-teardown, so drop the round instead.
            if (state->session->isClosing())
            {
                state->done.set_value(0);
                return;
            }
            state->session->run_in_session_thread([state]() { state->done.set_value(apply_round_on_session_thread(state)); });
        })
        .detach();
}

/// Synchronous round for a caller already on the session thread (the RPC handler runs
/// there in this client): a worker-and-future round would post its apply task back to
/// the very thread that is blocking on the round's future — a self-deadlock. Probe
/// inline without the lock instead, then apply inline under the lock.
uint32_t run_round_in_session_thread(tr_session* session, bool remove_unrecoverable)
{
    auto state = std::make_shared<RecoveryState>();
    state->session = session;
    state->remove_unrecoverable = remove_unrecoverable;

    {
        // Same shutdown-aware, one-round-at-a-time submission as the async path.
        auto lock = session->unique_lock();
        if (session->isClosing() || round_in_flight.exchange(true))
        {
            return 0;
        }

        state->snapshot();
    }

    state->probe();

    if (session->isClosing())
    {
        round_in_flight = false;
        return 0;
    }

    auto const changed = apply_round_on_session_thread(state);
    round_in_flight = false;
    return changed;
}

} // namespace

} // namespace missing_data_recovery

uint32_t tr_sessionRecoverMissingData(tr_session* session, bool remove_unrecoverable)
{
    if (session == nullptr)
    {
        return 0;
    }

    if (session->am_in_session_thread())
    {
        return missing_data_recovery::run_round_in_session_thread(session, remove_unrecoverable);
    }

    auto state = std::make_shared<missing_data_recovery::RecoveryState>();
    state->session = session;
    state->remove_unrecoverable = remove_unrecoverable;

    {
        // Shutdown-aware submission: a round submitted while the session is closing
        // would run mid-teardown. The check is serialized against close under the
        // session lock, which also guards the snapshot phase.
        auto lock = session->unique_lock();
        if (session->isClosing())
        {
            return 0;
        }

        // Retain the in-flight guard until this round has actually been applied: a
        // second caller (RPC or the periodic GTK hook) gets a prompt 0 instead of
        // racing an outstanding round.
        if (missing_data_recovery::round_in_flight.exchange(true))
        {
            return 0;
        }

        state->snapshot();
    }

    missing_data_recovery::start_round(state);

    // No arbitrary timeout: once submitted, the session thread runs this round's tasks
    // to completion (they are ordered before the queued close task), so completion is
    // guaranteed and the returned count is never a lie about an unfinished round.
    auto const changed = state->done.get_future().get();
    missing_data_recovery::round_in_flight = false;
    return changed;
}
