// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

@import AppKit;

#include <sys/resource.h>

#include <libtransmission/transmission.h>

#include <libtransmission/utils.h>

int main(int argc, char** argv)
{
    // Set background priority (equivalent to taskpolicy -b)
    // CPU: use PRIO_DARWIN_BG to prefer efficiency cores on Apple Silicon
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
    // I/O: throttle disk operations
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE);

    tr_lib_init();

    tr_locale_set_global("");

    return NSApplicationMain(argc, (char const**)argv);
}
