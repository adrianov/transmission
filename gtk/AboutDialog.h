// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#include <gtkmm/window.h>

// Shows the modal "About Transmission" dialog (credits, version, license),
// transient for the given parent window.
void gtr_show_about_dialog(Gtk::Window& parent);
