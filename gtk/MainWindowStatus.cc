// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "Prefs.h"
#include "Torrent.h"

#include <libtransmission/transmission.h>
#include <libtransmission/values.h>

#include <glibmm/i18n.h>

#include <fmt/format.h>

using namespace libtransmission::Values;

void MainWindow::Impl::updateStats()
{
    Glib::ustring buf;
    auto const* const session = core_->get_session();

    if (auto const pch = gtr_pref_string_get(TR_KEY_statusbar_stats); pch == "session-ratio")
    {
        auto const stats = tr_sessionGetStats(session);
        buf = fmt::format(fmt::runtime(_("Ratio: {ratio}")), fmt::arg("ratio", tr_strlratio(stats.ratio)));
    }
    else if (pch == "session-transfer")
    {
        auto const stats = tr_sessionGetStats(session);
        buf = fmt::format(
            fmt::runtime(C_("current session totals", "Down: {downloaded_size}, Up: {uploaded_size}")),
            fmt::arg("downloaded_size", tr_strlsize(stats.downloadedBytes)),
            fmt::arg("uploaded_size", tr_strlsize(stats.uploadedBytes)));
    }
    else if (pch == "total-transfer")
    {
        auto const stats = tr_sessionGetCumulativeStats(session);
        buf = fmt::format(
            fmt::runtime(C_("all-time totals", "Down: {downloaded_size}, Up: {uploaded_size}")),
            fmt::arg("downloaded_size", tr_strlsize(stats.downloadedBytes)),
            fmt::arg("uploaded_size", tr_strlsize(stats.uploadedBytes)));
    }
    else
    {
        auto const stats = tr_sessionGetCumulativeStats(session);
        buf = fmt::format(fmt::runtime(_("Ratio: {ratio}")), fmt::arg("ratio", tr_strlratio(stats.ratio)));
    }

    stats_lb_->set_text(buf);
}

void MainWindow::Impl::updateSpeeds()
{
    auto const* const session = core_->get_session();

    if (session != nullptr)
    {
        auto dn_count = int{};
        auto dn_speed = Speed{};
        auto up_count = int{};
        auto up_speed = Speed{};

        auto const model = core_->get_model();
        for (auto i = 0U, count = model->get_n_items(); i < count; ++i)
        {
            auto const torrent = gtr_ptr_dynamic_cast<Torrent>(model->get_object(i));
            dn_count += torrent->get_active_peers_down();
            dn_speed += torrent->get_speed_down();
            up_count += torrent->get_active_peers_up();
            up_speed += torrent->get_speed_up();
        }

        dl_lb_->set_text(fmt::format(fmt::runtime(_("{download_speed} ▼")), fmt::arg("download_speed", dn_speed.to_string())));
        dl_lb_->set_visible(dn_count > 0);

        ul_lb_->set_text(fmt::format(fmt::runtime(_("{upload_speed} ▲")), fmt::arg("upload_speed", up_speed.to_string())));
        ul_lb_->set_visible(dn_count > 0 || up_count > 0);
    }
}

void MainWindow::Impl::refresh()
{
    if (core_ != nullptr && core_->get_session() != nullptr)
    {
        updateSpeeds();
        updateStats();
    }
}
