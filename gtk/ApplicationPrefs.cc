// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include "ApplicationPrefs.h"

#include "Prefs.h"

#include <libtransmission/log.h>
#include <libtransmission/transmission.h>
#include <libtransmission/variant.h>

void gtr_apply_session_pref(tr_session* tr, tr_quark const key)
{
    switch (key)
    {
    case TR_KEY_encryption:
        tr_sessionSetEncryption(tr, static_cast<tr_encryption_mode>(gtr_pref_int_get(key)));
        break;

    case TR_KEY_default_trackers:
        tr_sessionSetDefaultTrackers(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_download_dir:
        tr_sessionSetDownloadDir(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_message_level:
        tr_logSetLevel(static_cast<tr_log_level>(gtr_pref_int_get(key)));
        break;

    case TR_KEY_peer_port:
        tr_sessionSetPeerPort(tr, gtr_pref_int_get(key));
        break;

    case TR_KEY_blocklist_enabled:
        tr_blocklistSetEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_blocklist_url:
        tr_blocklistSetURL(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_speed_limit_down_enabled:
        tr_sessionLimitSpeed(tr, TR_DOWN, gtr_pref_flag_get(key));
        break;

    case TR_KEY_speed_limit_down:
        tr_sessionSetSpeedLimit_KBps(tr, TR_DOWN, gtr_pref_int_get(key));
        break;

    case TR_KEY_speed_limit_up_enabled:
        tr_sessionLimitSpeed(tr, TR_UP, gtr_pref_flag_get(key));
        break;

    case TR_KEY_speed_limit_up:
        tr_sessionSetSpeedLimit_KBps(tr, TR_UP, gtr_pref_int_get(key));
        break;

    case TR_KEY_ratio_limit_enabled:
        tr_sessionSetRatioLimited(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_ratio_limit:
        tr_sessionSetRatioLimit(tr, gtr_pref_double_get(key));
        break;

    case TR_KEY_idle_seeding_limit:
        tr_sessionSetIdleLimit(tr, gtr_pref_int_get(key));
        break;

    case TR_KEY_idle_seeding_limit_enabled:
        tr_sessionSetIdleLimited(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_port_forwarding_enabled:
        tr_sessionSetPortForwardingEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_pex_enabled:
        tr_sessionSetPexEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_rename_partial_files:
        tr_sessionSetIncompleteFileNamingEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_download_queue_size:
        tr_sessionSetQueueSize(tr, TR_DOWN, gtr_pref_int_get(key));
        break;

    case TR_KEY_queue_stalled_minutes:
        tr_sessionSetQueueStalledMinutes(tr, gtr_pref_int_get(key));
        break;

    case TR_KEY_dht_enabled:
        tr_sessionSetDHTEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_utp_enabled:
        tr_sessionSetUTPEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_lpd_enabled:
        tr_sessionSetLPDEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_rpc_port:
        tr_sessionSetRPCPort(tr, gtr_pref_int_get(key));
        break;

    case TR_KEY_rpc_enabled:
        tr_sessionSetRPCEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_rpc_whitelist:
        tr_sessionSetRPCWhitelist(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_rpc_whitelist_enabled:
        tr_sessionSetRPCWhitelistEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_rpc_username:
        tr_sessionSetRPCUsername(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_rpc_password:
        tr_sessionSetRPCPassword(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_rpc_authentication_required:
        tr_sessionSetRPCPasswordEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_alt_speed_up:
        tr_sessionSetAltSpeed_KBps(tr, TR_UP, gtr_pref_int_get(key));
        break;

    case TR_KEY_alt_speed_down:
        tr_sessionSetAltSpeed_KBps(tr, TR_DOWN, gtr_pref_int_get(key));
        break;

    case TR_KEY_alt_speed_time_begin:
        tr_sessionSetAltSpeedBegin(tr, gtr_pref_int_get(key));
        break;

    case TR_KEY_alt_speed_time_end:
        tr_sessionSetAltSpeedEnd(tr, gtr_pref_int_get(key));
        break;

    case TR_KEY_alt_speed_time_enabled:
        tr_sessionUseAltSpeedTime(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_alt_speed_time_day:
        tr_sessionSetAltSpeedDay(tr, static_cast<tr_sched_day>(gtr_pref_int_get(key)));
        break;

    case TR_KEY_peer_port_random_on_start:
        tr_sessionSetPeerPortRandomOnStart(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_incomplete_dir:
        tr_sessionSetIncompleteDir(tr, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_incomplete_dir_enabled:
        tr_sessionSetIncompleteDirEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_script_torrent_done_enabled:
        tr_sessionSetScriptEnabled(tr, TR_SCRIPT_ON_TORRENT_DONE, gtr_pref_flag_get(key));
        break;

    case TR_KEY_script_torrent_done_filename:
        tr_sessionSetScript(tr, TR_SCRIPT_ON_TORRENT_DONE, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_script_torrent_done_seeding_enabled:
        tr_sessionSetScriptEnabled(tr, TR_SCRIPT_ON_TORRENT_DONE_SEEDING, gtr_pref_flag_get(key));
        break;

    case TR_KEY_script_torrent_done_seeding_filename:
        tr_sessionSetScript(tr, TR_SCRIPT_ON_TORRENT_DONE_SEEDING, gtr_pref_string_get(key).c_str());
        break;

    case TR_KEY_start_added_torrents:
        tr_sessionSetPaused(tr, !gtr_pref_flag_get(key));
        break;

    case TR_KEY_trash_original_torrent_files:
        tr_sessionSetDeleteSource(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_torrent_complete_verify_enabled:
        tr_sessionSetCompleteVerifyEnabled(tr, gtr_pref_flag_get(key));
        break;

    case TR_KEY_proxy_url:
        {
            auto map = tr_variant::Map{ 1U };
            if (auto const s = gtr_pref_string_get(key); s.empty())
            {
                map.try_emplace(key, nullptr);
            }
            else
            {
                map.try_emplace(key, s);
            }
            tr_sessionSet(tr, tr_variant{ std::move(map) });
            break;
        }

    default:
        break;
    }
}
