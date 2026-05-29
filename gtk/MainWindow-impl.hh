#pragma once

#include "FilterBar.h"
#include "GtkCompat.h"
#include "Session.h"

#include <giomm/actiongroup.h>
#include <giomm/menu.h>
#include <giomm/menuitem.h>
#include <giomm/simpleactiongroup.h>
#include <glibmm/refptr.h>
#include <gtkmm/image.h>
#include <gtkmm/label.h>
#include <gtkmm/scrolledwindow.h>
#include <gtkmm/togglebutton.h>
#include <gtkmm/treeview.h>
#include <gtkmm/widget.h>

#if GTKMM_CHECK_VERSION(4, 0, 0)
#include <gtkmm/listitemfactory.h>
#include <gtkmm/multiselection.h>
#include <gtkmm/popovermenu.h>
#else
#include <gtkmm/menu.h>
#include <gtkmm/treeviewcolumn.h>
#endif

#include <array>
#include <functional>
#include <map>
#include <memory>
#include <string>

class MainWindow;
class TorrentCellRenderer;

class MainWindow::Impl
{
    struct OptionMenuInfo
    {
        Glib::RefPtr<Gio::SimpleAction> action;
        Glib::RefPtr<Gio::MenuItem> on_item;
        Glib::RefPtr<Gio::Menu> section;
    };

    using TorrentView = IF_GTKMM4(Gtk::ListView, Gtk::TreeView);
    using TorrentViewSelection = IF_GTKMM4(Gtk::MultiSelection, Gtk::TreeSelection);

public:
    Impl(
        MainWindow& window,
        Glib::RefPtr<Gtk::Builder> const& builder,
        Glib::RefPtr<Gio::ActionGroup> const& actions,
        Glib::RefPtr<Session> const& core);
    Impl(Impl&&) = delete;
    Impl(Impl const&) = delete;
    Impl& operator=(Impl&&) = delete;
    Impl& operator=(Impl const&) = delete;
    ~Impl();

    [[nodiscard]] Glib::RefPtr<TorrentViewSelection> get_selection() const;

    void refresh();

    void prefsChanged(tr_quark key);

    auto& signal_selection_changed()
    {
        return signal_selection_changed_;
    }

private:
    void init_view(TorrentView* view, Glib::RefPtr<FilterBar::Model> const& model);

    Glib::RefPtr<Gio::MenuModel> createOptionsMenu();
    Glib::RefPtr<Gio::MenuModel> createSpeedMenu(Glib::RefPtr<Gio::SimpleActionGroup> const& actions, tr_direction dir);
    Glib::RefPtr<Gio::MenuModel> createRatioMenu(Glib::RefPtr<Gio::SimpleActionGroup> const& actions);

    Glib::RefPtr<Gio::MenuModel> createStatsMenu();

    void on_popup_menu(double event_x, double event_y);

    void onSpeedToggled(std::string const& action_name, tr_direction dir, bool enabled);
    void onSpeedSet(tr_direction dir, int KBps);

    void onRatioToggled(std::string const& action_name, bool enabled);
    void onRatioSet(double ratio);

    void updateStats();
    void updateSpeeds();

    void syncAltSpeedButton();

    void status_menu_toggled_cb(std::string const& action_name, Glib::ustring const& val);
    void onOptionsClicked();
    void alt_speed_toggled_cb();
    void onAltSpeedToggledIdle();

private:
    MainWindow& window_;
    Glib::RefPtr<Session> const core_;

    sigc::signal<void()> signal_selection_changed_;

    Glib::RefPtr<Gio::ActionGroup> options_actions_;
    Glib::RefPtr<Gio::ActionGroup> stats_actions_;

    std::array<OptionMenuInfo, 2> speed_menu_info_;
    OptionMenuInfo ratio_menu_info_;

#if GTKMM_CHECK_VERSION(4, 0, 0)
    Glib::RefPtr<Gtk::ListItemFactory> item_factory_compact_;
    Glib::RefPtr<Gtk::ListItemFactory> item_factory_full_;
    Glib::RefPtr<Gtk::MultiSelection> selection_;
#else
    TorrentCellRenderer* renderer_ = nullptr;
    Gtk::TreeViewColumn* column_ = nullptr;
#endif

    Gtk::ScrolledWindow* scroll_ = nullptr;
    TorrentView* view_ = nullptr;
    Gtk::Widget* toolbar_ = nullptr;
    FilterBar* filter_;
    Gtk::Widget* status_ = nullptr;
    Gtk::Label* ul_lb_ = nullptr;
    Gtk::Label* dl_lb_ = nullptr;
    Gtk::Label* stats_lb_ = nullptr;
    Gtk::Image* alt_speed_image_ = nullptr;
    Gtk::ToggleButton* alt_speed_button_ = nullptr;
    sigc::connection pref_handler_id_;
    IF_GTKMM4(Gtk::PopoverMenu*, Gtk::Menu*) popup_menu_ = nullptr;
};
