// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "Actions.h"
#include "Prefs.h"
#include "Torrent.h"
#include "Utils.h"

#if GTKMM_CHECK_VERSION(4, 0, 0)
#include "PiecesProgressBar.h"
#else
#include "TorrentCellRenderer.h"
#endif

#include <glibmm/miscutils.h>

#include <memory>
#include <string>

using namespace std::string_literals;

namespace
{

auto constexpr OpenTorrentFile = []()
{
    gtr_action_activate(GTR_KEY_open_torrent_file);
};

#if GTKMM_CHECK_VERSION(4, 0, 0)

class GtrStrvBuilderDeleter
{
public:
    void operator()(GStrvBuilder* builder) const
    {
        if (builder != nullptr)
        {
            g_strv_builder_unref(builder);
        }
    }
};

using GtrStrvBuilderPtr = std::unique_ptr<GStrvBuilder, GtrStrvBuilderDeleter>;

GStrv gtr_strv_join(GObject* /*object*/, GStrv lhs, GStrv rhs)
{
    auto const builder = GtrStrvBuilderPtr(g_strv_builder_new());
    if (builder == nullptr)
    {
        return nullptr;
    }

    g_strv_builder_addv(builder.get(), const_cast<char const**>(lhs)); // NOLINT(cppcoreguidelines-pro-type-const-cast)
    g_strv_builder_addv(builder.get(), const_cast<char const**>(rhs)); // NOLINT(cppcoreguidelines-pro-type-const-cast)

    return g_strv_builder_end(builder.get());
}

#else

bool tree_view_search_equal_func(
    Glib::RefPtr<Gtk::TreeModel> const& /*model*/,
    int /*column*/,
    Glib::ustring const& key,
    Gtk::TreeModel::const_iterator const& iter)
{
    static auto const& self_col = Torrent::get_columns().self;

    auto const name = iter->get_value(self_col)->get_name_collated();
    return name.find(key.lowercase()) == Glib::ustring::npos;
}

#endif

} // namespace

void MainWindow::Impl::init_view(TorrentView* view, Glib::RefPtr<FilterBar::Model> const& model)
{
#if GTKMM_CHECK_VERSION(4, 0, 0)
    auto const create_builder_list_item_factory = [](std::string const& filename)
    {
        auto builder_scope = Glib::wrap(G_OBJECT(gtk_builder_cscope_new()));
        gtk_builder_cscope_add_callback(GTK_BUILDER_CSCOPE(builder_scope->gobj()), gtr_strv_join);

        return Glib::wrap(gtk_builder_list_item_factory_new_from_resource(
            GTK_BUILDER_CSCOPE(builder_scope->gobj()),
            gtr_get_full_resource_path(filename).c_str()));
    };

    PiecesProgressBar::ensure_registered();

    item_factory_compact_ = create_builder_list_item_factory("TorrentListItemCompact.ui"s);
    item_factory_full_ = create_builder_list_item_factory("TorrentListItemFull.ui"s);

    view->signal_activate().connect([](guint /*position*/) { OpenTorrentFile(); });

    selection_ = Gtk::MultiSelection::create(model);
    selection_->signal_selection_changed().connect([this](guint /*position*/, guint /*n_items*/)
                                                   { signal_selection_changed_.emit(); });

    view->set_factory(gtr_pref_flag_get(TR_KEY_compact_view) ? item_factory_compact_ : item_factory_full_);
    view->set_model(selection_);
#else
    static auto const& torrent_cols = Torrent::get_columns();

    view->set_search_column(torrent_cols.name_collated);
    view->set_search_equal_func(&tree_view_search_equal_func);

    column_ = view->get_column(0);

    renderer_ = Gtk::make_managed<TorrentCellRenderer>();
    column_->pack_start(*renderer_, false);
    column_->add_attribute(renderer_->property_torrent(), torrent_cols.self);

    view->signal_popup_menu().connect_notify([this]() { on_popup_menu(0, 0); });
    view->signal_row_activated().connect([](auto const& /*path*/, auto* /*column*/) { OpenTorrentFile(); });

    view->set_model(model);

    view->get_selection()->signal_changed().connect([this]() { signal_selection_changed_.emit(); });
#endif

    setup_item_view_button_event_handling(
        *view,
        [this, view](guint /*button*/, TrGdkModifierType /*state*/, double view_x, double view_y, bool context_menu_requested)
        {
            return on_item_view_button_pressed(
                *view,
                view_x,
                view_y,
                context_menu_requested,
                sigc::mem_fun(*this, &Impl::on_popup_menu));
        },
        [view](double view_x, double view_y) { return on_item_view_button_released(*view, view_x, view_y); });
}
