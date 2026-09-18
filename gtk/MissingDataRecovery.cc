// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// GTK plumbing for the missing-data recovery feature ("No data found!" torrents): on
// launch and on every refresh tick while some torrent is in local-error state, invoke
// the shared implementation `tr_sessionRecoverMissingData()` — from a worker thread, so
// its filesystem probing never blocks the UI — and rate-limit consecutive rounds that
// changed nothing. See libtransmission/missing-data-recovery.cc for the recovery rules.

#include "MissingDataRecovery.h"

#include "Session.h"
#include "Torrent.h"
#include "Utils.h"

#include <libtransmission/transmission.h>

#include <glibmm/ustring.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <thread>
#include <utility>

#include <glib.h>

namespace gtr_missing_data
{

namespace
{

/// True when some torrent is in local-error state. The model caches each torrent's stat
/// error, so this stays cheap.
bool any_torrent_in_local_error(Glib::RefPtr<Session> const& core)
{
    auto const model = core->get_model();
    for (auto i = 0U, n_items = model->get_n_items(); i < n_items; ++i)
    {
        if (auto const torrent = gtr_ptr_dynamic_cast<Torrent>(model->get_object(i));
            torrent != nullptr && torrent->get_error_code() == TR_STAT_LOCAL_ERROR)
        {
            return true;
        }
    }

    return false;
}

// Main-thread-only call-rate state. Rounds that change nothing (e.g. a relocation the
// session thread cannot complete, or storage that stays unavailable) back off
// exponentially; any round that changes something resets the backoff.
bool busy = false;
int failures = 0;
std::int64_t next_ok_us = 0;

int invoke_main_trampoline(void* data)
{
    auto* fn = static_cast<std::function<void()>*>(data);
    (*fn)();
    delete fn;
    return G_SOURCE_REMOVE;
}

void on_round_finished(Glib::RefPtr<Session> const& core, uint32_t changed)
{
    busy = false;

    if (changed > 0 || !any_torrent_in_local_error(core))
    {
        failures = 0;
        next_ok_us = 0;
        return;
    }

    failures = std::min(failures + 1, 6);
    next_ok_us = g_get_monotonic_time() + (1 << failures) * std::int64_t{ G_USEC_PER_SEC };
}

void run_recovery_round(Glib::RefPtr<Session> const& core, bool remove_unrecoverable)
{
    if (busy || g_get_monotonic_time() < next_ok_us)
    {
        return;
    }

    busy = true;
    auto const session = core->get_session();
    std::thread(
        [core, session, remove_unrecoverable]()
        {
            auto const changed = tr_sessionRecoverMissingData(session, remove_unrecoverable);
            // Owned by the main loop; must own its captures, not borrow from this
            // (already exiting) worker lambda.
            auto* const fn = new std::function<void()>([core, changed]() { on_round_finished(core, changed); });
            g_main_context_invoke(nullptr, &invoke_main_trampoline, fn);
        })
        .detach();
}

} // namespace

void recover_or_remove_on_launch(Glib::RefPtr<Session> const& core)
{
    if (core->get_torrent_count() != 0)
    {
        run_recovery_round(core, true);
    }
}

void relocate_errored_torrents_if_accessible(Glib::RefPtr<Session> const& core)
{
    if (any_torrent_in_local_error(core))
    {
        run_recovery_round(core, false);
    }
}

} // namespace gtr_missing_data
