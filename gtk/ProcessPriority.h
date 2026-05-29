// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

// Adjusts the process scheduling and I/O priority so Transmission yields CPU and
// disk to foreground applications while it is backgrounded, and restores normal
// priority when it is active again. All adjustments are reversible and require no
// elevated privileges. No-op on non-Linux platforms.
class ProcessPriority
{
public:
    // background == true lowers priority (batch scheduling + idle I/O);
    // background == false restores normal interactive priority.
    void set_background(bool background);

private:
    bool is_background_ = false;
};
