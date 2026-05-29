// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "ProcessPriority.h"

#ifdef __linux__
#include <sched.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace
{
// Linux I/O priority constants (from <linux/ioprio.h>, not always available in user space)
auto constexpr IoPrioWhoProcess = 1;
auto constexpr IoPrioClassBE = 2; // best-effort (default)
auto constexpr IoPrioClassIdle = 3; // idle

constexpr int make_ioprio(int ioclass, int data)
{
    return (ioclass << 13) | data;
}
} // namespace
#endif

void ProcessPriority::set_background(bool background)
{
    if (background == is_background_)
    {
        return;
    }

#ifdef __linux__
    // SCHED_BATCH marks this as a non-interactive batch workload so the scheduler
    // deprioritises it; SCHED_OTHER restores the normal interactive class. Pairing
    // this with the idle/best-effort I/O class keeps disk access out of the way too.
    struct sched_param const sp = {};
    sched_setscheduler(0, background ? SCHED_BATCH : SCHED_OTHER, &sp);
    syscall(SYS_ioprio_set, IoPrioWhoProcess, 0, make_ioprio(background ? IoPrioClassIdle : IoPrioClassBE, 0));
#endif

    is_background_ = background;
}
