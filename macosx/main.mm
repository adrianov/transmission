// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

@import AppKit;

#include <sys/resource.h>

#include <libtransmission/transmission.h>

#include <libtransmission/utils.h>

int main(int argc, char** argv)
{
    // Set background I/O priority (equivalent to taskpolicy -b)
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE);

    tr_lib_init();

    tr_locale_set_global("");

    return NSApplicationMain(argc, (char const**)argv);
}
