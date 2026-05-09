// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "Actions.h"

#include "Prefs.h"
#include "PrefsDialog.h"
#include "Session.h"
#include "Utils.h"

#include <libtransmission/quark.h>

#include <giomm/simpleaction.h>
#include <glibmm/i18n.h>
#include <glibmm/variant.h>

#include <array>
#include <initializer_list>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include <gtkmm/application.h>

using namespace std::string_view_literals;

using VariantString = Glib::Variant<Glib::ustring>;

namespace
{

Session* myCore = nullptr;

void action_cb(Gio::SimpleAction& action, gpointer user_data)
{
    gtr_actions_handler(action.get_name(), user_data);
}

void sort_changed_cb(Gio::SimpleAction& action, Glib::VariantBase const& value, gpointer /*user_data*/)
{
    action.set_state(value);
    myCore->set_pref(TR_KEY_sort_mode, Glib::VariantBase::cast_dynamic<Glib::Variant<Glib::ustring>>(value).get());
}

auto const show_toggle_entries = std::array<Glib::ustring, 2U>{ GTR_KEY_toggle_main_window, GTR_KEY_toggle_message_log };

void toggle_pref_cb(Gio::SimpleAction& action, gpointer /*user_data*/)
{
    auto const key = action.get_name();
    bool val = false;
    action.get_state(val);

    action.set_state(Glib::Variant<bool>::create(!val));

    myCore->set_pref(tr_quark_new({ key.c_str(), key.size() }), !val);
}

std::array<tr_quark, 7> const pref_toggle_entries = {
    TR_KEY_alt_speed_enabled, //
    TR_KEY_compact_view, //
    TR_KEY_sort_reversed, //
    TR_KEY_show_filterbar, //
    TR_KEY_show_pieces_bar, //
    TR_KEY_show_statusbar, //
    TR_KEY_show_toolbar, //
};

auto const entries = std::array<Glib::ustring, 29>{
    GTR_KEY_copy_magnet_link_to_clipboard,
    GTR_KEY_open_torrent_from_url,
    GTR_KEY_open_torrent,
    GTR_KEY_torrent_start,
    GTR_KEY_torrent_start_now,
    GTR_KEY_show_stats,
    GTR_KEY_donate,
    GTR_KEY_torrent_verify,
    GTR_KEY_torrent_stop,
    GTR_KEY_pause_all_torrents,
    GTR_KEY_start_all_torrents,
    GTR_KEY_relocate_torrent,
    GTR_KEY_remove_torrent,
    GTR_KEY_delete_torrent,
    GTR_KEY_new_torrent,
    GTR_KEY_quit,
    GTR_KEY_select_all,
    GTR_KEY_deselect_all,
    GTR_KEY_edit_preferences,
    GTR_KEY_show_torrent_properties,
    GTR_KEY_open_torrent_folder,
    GTR_KEY_show_about_dialog,
    GTR_KEY_help,
    GTR_KEY_torrent_reannounce,
    GTR_KEY_queue_move_top,
    GTR_KEY_queue_move_up,
    GTR_KEY_queue_move_down,
    GTR_KEY_queue_move_bottom,
    GTR_KEY_present_main_window,
};

Gtk::Builder* myBuilder = nullptr;

std::unordered_map<Glib::ustring, Glib::RefPtr<Gio::SimpleAction>> key_to_action;

} // namespace

void gtr_actions_set_core(Glib::RefPtr<Session> const& core)
{
    myCore = core.get();
}

Glib::RefPtr<Gio::SimpleActionGroup> gtr_actions_init(Glib::RefPtr<Gtk::Builder> const& builder, gpointer callback_user_data)
{
    myBuilder = builder.get();

    auto action_group = Gio::SimpleActionGroup::create();

    auto const match = gtr_pref_string_get(TR_KEY_sort_mode);

    {
        auto const action_name = GTR_KEY_sort_torrents;
        auto const action = Gio::SimpleAction::create_radio_string(action_name, match);
        action->signal_activate().connect([a = action.get(), callback_user_data](auto const& value)
                                          { sort_changed_cb(*a, value, callback_user_data); });
        action_group->add_action(action);
        key_to_action.try_emplace(action_name, action);
    }

    for (auto const& action_name_view : show_toggle_entries)
    {
        auto const action_name = Glib::ustring(std::string(action_name_view));
        auto const action = Gio::SimpleAction::create_bool(action_name);
        action->signal_activate().connect([a = action.get(), callback_user_data](auto const& /*value*/)
                                          { action_cb(*a, callback_user_data); });
        action_group->add_action(action);
        key_to_action.try_emplace(action_name, action);
    }

    for (auto const action_name_quark : pref_toggle_entries)
    {
        auto const action_name_sv = tr_quark_get_string_view(action_name_quark);
        auto const action_name = Glib::ustring{ std::data(action_name_sv), std::size(action_name_sv) };
        auto const action = Gio::SimpleAction::create_bool(action_name, gtr_pref_flag_get(action_name_quark));
        action->signal_activate().connect([a = action.get(), callback_user_data](auto const& /*value*/)
                                          { toggle_pref_cb(*a, callback_user_data); });
        action_group->add_action(action);
        key_to_action.try_emplace(action_name, action);
    }

    for (auto const& action_name_view : entries)
    {
        auto const action_name = Glib::ustring(std::string(action_name_view));
        auto const action = Gio::SimpleAction::create(action_name);
        action->signal_activate().connect([a = action.get(), callback_user_data](auto const& /*value*/)
                                          { action_cb(*a, callback_user_data); });
        action_group->add_action(action);
        key_to_action.try_emplace(action_name, action);
    }

    return action_group;
}

/****
*****
****/

namespace
{

Glib::RefPtr<Gio::SimpleAction> get_action(Glib::ustring const& name)
{
    return key_to_action.at(name);
}

} // namespace

void gtr_action_activate(Glib::ustring const& name)
{
    get_action(name)->activate();
}

void gtr_action_set_sensitive(Glib::ustring const& name, bool is_sensitive)
{
    get_action(name)->set_enabled(is_sensitive);
}

void gtr_action_set_toggled(Glib::ustring const& name, bool is_toggled)
{
    get_action(name)->change_state(is_toggled);
}

Glib::RefPtr<Glib::Object> gtr_action_get_object(Glib::ustring const& name)
{
    return myBuilder->get_object(name);
}

namespace
{

void bind_action_accel(Gtk::Application& app, char const* const detailed_action, std::initializer_list<char const*> accels)
{
    auto v = std::vector<char const*>{ accels.begin(), accels.end() };
    v.push_back(nullptr);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app.gobj()), detailed_action, v.data());
}

} // namespace

void gtr_application_bind_menu_accels(Gtk::Application& app)
{
    bind_action_accel(app, "win.open_torrent", { "<Control>o" });
    bind_action_accel(app, "win.open_torrent_from_url", { "<Control>u" });
    bind_action_accel(app, "win.new_torrent", { "<Control>n" });
    bind_action_accel(app, "win.quit", { "<Control>q" });
    bind_action_accel(app, "win.select_all", { "<Control>a" });
    bind_action_accel(app, "win.deselect_all", { "<Shift><Control>a" });
    bind_action_accel(app, "win.show_torrent_properties", { "<Alt>Return" });
    bind_action_accel(app, "win.open_torrent_folder", { "<Control>e" });
    bind_action_accel(app, "win.torrent_start", { "<Control>s" });
    bind_action_accel(app, "win.torrent_start_now", { "<Shift><Control>s" });
    bind_action_accel(app, "win.torrent_stop", { "<Control>p" });
    bind_action_accel(app, "win.relocate_torrent", { "<Control>v" });
    bind_action_accel(app, "win.remove_torrent", { "Delete" });
    bind_action_accel(app, "win.delete_torrent", { "<Shift>Delete" });
    bind_action_accel(app, "win.compact_view", { "<Alt>c" });
    bind_action_accel(app, "win.help", { "F1" });
}
