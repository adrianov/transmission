// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include "libtransmission/api-compat.h"
#include "libtransmission/bandwidth.h"
#include "libtransmission/file.h"
#include "libtransmission/interned-string.h"
#include "libtransmission/quark.h"
#include "libtransmission/session.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/variant.h"

using namespace std::literals;
using namespace libtransmission::Values;

namespace
{
auto constexpr BandwidthGroupsFilename = "bandwidth-groups.json"sv;
}

void tr_session_bandwidth_groups_read(tr_session* session, std::string_view config_dir)
{
    auto const filename = tr_pathbuf{ config_dir, '/', BandwidthGroupsFilename };
    if (!tr_sys_path_exists(filename))
        return;

    auto groups_var = tr_variant_serde::json().parse_file(filename);
    if (!groups_var)
        return;
    libtransmission::api_compat::convert_incoming_data(*groups_var);

    auto const* const groups_map = groups_var->get_if<tr_variant::Map>();
    if (groups_map == nullptr)
        return;

    for (auto const& [key, group_var] : *groups_map)
    {
        auto const* const group_map = group_var.get_if<tr_variant::Map>();
        if (group_map == nullptr)
            continue;

        auto& group = session->getBandwidthGroup(tr_interned_string{ key });
        auto limits = tr_bandwidth_limits{};

        if (auto const val = group_map->value_if<bool>(TR_KEY_upload_limited); val)
            limits.up_limited = *val;
        if (auto const val = group_map->value_if<bool>(TR_KEY_download_limited); val)
            limits.down_limited = *val;
        if (auto const val = group_map->value_if<int64_t>(TR_KEY_upload_limit); val)
            limits.up_limit = Speed{ *val, Speed::Units::KByps };
        if (auto const val = group_map->value_if<int64_t>(TR_KEY_download_limit); val)
            limits.down_limit = Speed{ *val, Speed::Units::KByps };

        group.set_limits(limits);

        if (auto const val = group_map->value_if<bool>(TR_KEY_honors_session_limits); val)
        {
            group.honor_parent_limits(TR_UP, *val);
            group.honor_parent_limits(TR_DOWN, *val);
        }
    }
}

void tr_session_bandwidth_groups_write(tr_session const* session, std::string_view config_dir)
{
    auto const& groups = session->bandwidthGroups();
    auto groups_map = tr_variant::Map{ std::size(groups) };
    for (auto const& [name, group] : groups)
    {
        auto const limits = group->get_limits();
        auto group_map = tr_variant::Map{ 6U };
        group_map.try_emplace(TR_KEY_download_limit, limits.down_limit.count(Speed::Units::KByps));
        group_map.try_emplace(TR_KEY_download_limited, limits.down_limited);
        group_map.try_emplace(TR_KEY_honors_session_limits, group->are_parent_limits_honored(TR_UP));
        group_map.try_emplace(TR_KEY_name, name.sv());
        group_map.try_emplace(TR_KEY_upload_limit, limits.up_limit.count(Speed::Units::KByps));
        group_map.try_emplace(TR_KEY_upload_limited, limits.up_limited);
        groups_map.try_emplace(name.quark(), std::move(group_map));
    }

    auto out = tr_variant{ std::move(groups_map) };
    libtransmission::api_compat::convert_outgoing_data(out);
    tr_variant_serde::json().to_file(out, tr_pathbuf{ config_dir, '/', BandwidthGroupsFilename });
}
