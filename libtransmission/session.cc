// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <algorithm> // std::partial_sort(), std::min(), std::max()
#include <condition_variable>
#include <chrono>
#include <csignal>
#include <cstddef> // size_t
#include <cstdint>
#include <ctime>
#include <future>
#include <iterator> // for std::back_inserter
#include <limits> // std::numeric_limits
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <sys/stat.h> /* umask() */
#endif

#include <event2/event.h>

#include <fmt/format.h> // fmt::ptr

#include "libtransmission/transmission.h"

#include "libtransmission/api-compat.h"
#include "libtransmission/bandwidth.h"
#include "libtransmission/blocklist.h"
#include "libtransmission/cache.h"
#include "libtransmission/crypto-utils.h"
#include "libtransmission/file.h"
#include "libtransmission/ip-cache.h"
#include "libtransmission/interned-string.h"
#include "libtransmission/log.h"
#include "libtransmission/net.h"
#include "libtransmission/peer-mgr.h"
#include "libtransmission/peer-socket.h"
#include "libtransmission/port-forwarding.h"
#include "libtransmission/quark.h"
#include "libtransmission/rpc-server.h"
#include "libtransmission/session.h"
#include "libtransmission/session-alt-speeds.h"
#include "libtransmission/session-bandwidth-groups.h"
#include "libtransmission/session-disk-space.h"
#include "libtransmission/timer-ev.h"
#include "libtransmission/torrent.h"
#include "libtransmission/torrent-ctor.h"
#include "libtransmission/tr-assert.h"
#include "libtransmission/tr-dht.h"
#include "libtransmission/tr-lpd.h"
#include "libtransmission/tr-strbuf.h"
#include "libtransmission/tr-utp.h"
#include "libtransmission/utils.h"
#include "libtransmission/variant.h"
#include "libtransmission/version.h"
#include "libtransmission/web.h"

struct tr_ctor;

using namespace std::literals;
using namespace libtransmission::Values;

void tr_session::update_bandwidth(tr_direction const dir)
{
    if (auto const limit = active_speed_limit(dir); limit)
    {
        top_bandwidth_.set_limited(dir, limit->base_quantity() > 0U);
        top_bandwidth_.set_desired_speed(dir, *limit);
    }
    else
    {
        top_bandwidth_.set_limited(dir, false);
    }
}

tr_port tr_session::randomPort() const
{
    auto const lower = std::min(settings_.peer_port_random_low.host(), settings_.peer_port_random_high.host());
    auto const upper = std::max(settings_.peer_port_random_low.host(), settings_.peer_port_random_high.host());
    auto const range = upper - lower;
    return tr_port::from_host(lower + tr_rand_int(range + 1U));
}

/* Generate a peer id : "-TRxyzb-" + 12 random alphanumeric
   characters, where x is the major version number, y is the
   minor version number, z is the maintenance number, and b
   designates beta (Azureus-style) */
tr_peer_id_t tr_peerIdInit()
{
    auto peer_id = tr_peer_id_t{};
    auto* it = std::data(peer_id);

    // starts with -TRXXXX-
    auto constexpr Prefix = std::string_view{ PEERID_PREFIX };
    auto const* const end = it + std::size(peer_id);
    it = std::copy_n(std::data(Prefix), std::size(Prefix), it);

    // remainder is randomly-generated characters
    auto constexpr Pool = std::string_view{ "0123456789abcdefghijklmnopqrstuvwxyz" };
    auto total = 0;
    tr_rand_buffer(it, end - it);
    while (it + 1 < end)
    {
        int const val = *it % std::size(Pool);
        total += val;
        *it++ = Pool[val];
    }
    int const val = total % std::size(Pool) != 0 ? std::size(Pool) - (total % std::size(Pool)) : 0;
    *it = Pool[val];

    return peer_id;
}

// ---

std::vector<tr_torrent_id_t> tr_session::DhtMediator::torrents_allowing_dht() const
{
    auto ids = std::vector<tr_torrent_id_t>{};
    auto const& torrents = session_.torrents();

    ids.reserve(std::size(torrents));
    for (auto const* const tor : torrents)
    {
        if (tor->is_running() && tor->allows_dht())
        {
            ids.push_back(tor->id());
        }
    }

    return ids;
}

tr_sha1_digest_t tr_session::DhtMediator::torrent_info_hash(tr_torrent_id_t id) const
{
    if (auto const* const tor = session_.torrents().get(id); tor != nullptr)
    {
        return tor->info_hash();
    }

    return {};
}

void tr_session::DhtMediator::add_pex(tr_sha1_digest_t const& info_hash, tr_pex const* pex, size_t n_pex)
{
    if (auto* const tor = session_.torrents().get(info_hash); tor != nullptr)
    {
        tr_peerMgrAddPex(tor, TR_PEER_FROM_DHT, pex, n_pex);
    }
}

// ---

std::string tr_session::QueueMediator::store_filename(tr_torrent_id_t id) const
{
    auto const* const tor = session_.torrents().get(id);
    return tor != nullptr ? tor->store_filename() : std::string{};
}

// ---

bool tr_session::LpdMediator::onPeerFound(std::string_view info_hash_str, tr_address address, tr_port port)
{
    auto const digest = tr_sha1_from_string(info_hash_str);
    if (!digest)
    {
        return false;
    }

    tr_torrent* const tor = session_.torrents_.get(*digest);
    if (!tr_isTorrent(tor) || !tor->allows_lpd())
    {
        return false;
    }

    // we found a suitable peer, add it to the torrent
    auto const socket_address = tr_socket_address{ address, port };
    auto const pex = tr_pex{ socket_address };
    tr_peerMgrAddPex(tor, TR_PEER_FROM_LPD, &pex, 1U);
    tr_logAddDebugTor(tor, fmt::format("Found a local peer from LPD ({:s})", socket_address.display_name()));
    return true;
}

std::vector<tr_lpd::Mediator::TorrentInfo> tr_session::LpdMediator::torrents() const
{
    auto ret = std::vector<tr_lpd::Mediator::TorrentInfo>{};
    ret.reserve(std::size(session_.torrents()));
    for (auto const* const tor : session_.torrents())
    {
        auto info = tr_lpd::Mediator::TorrentInfo{};
        info.info_hash_str = tor->info_hash_string();
        info.activity = tor->activity();
        info.allows_lpd = tor->allows_lpd();
        info.announce_after = tor->lpdAnnounceAt;
        ret.emplace_back(info);
    }
    return ret;
}

void tr_session::LpdMediator::setNextAnnounceTime(std::string_view info_hash_str, time_t announce_after)
{
    if (auto digest = tr_sha1_from_string(info_hash_str); digest)
    {
        if (tr_torrent* const tor = session_.torrents_.get(*digest); tr_isTorrent(tor))
        {
            tor->lpdAnnounceAt = announce_after;
        }
    }
}

// ---

std::optional<std::string> tr_session::WebMediator::cookieFile() const
{
    auto const path = tr_pathbuf{ session_->configDir(), "/cookies.txt"sv };

    if (!tr_sys_path_exists(path))
    {
        return {};
    }

    return std::string{ path };
}

std::optional<std::string_view> tr_session::WebMediator::userAgent() const
{
    return TR_NAME "/" SHORT_VERSION_STRING;
}

std::optional<std::string> tr_session::WebMediator::bind_address_V4() const
{
    if (auto const addr = session_->bind_address(TR_AF_INET); !addr.is_any())
    {
        return addr.display_name();
    }

    return std::nullopt;
}

std::optional<std::string> tr_session::WebMediator::bind_address_V6() const
{
    if (auto const addr = session_->bind_address(TR_AF_INET6); !addr.is_any())
    {
        return addr.display_name();
    }

    return std::nullopt;
}

size_t tr_session::WebMediator::clamp(int torrent_id, size_t byte_count) const
{
    auto const lock = session_->unique_lock();

    auto const* const tor = session_->torrents().get(torrent_id);
    return tor == nullptr ? 0U : tor->bandwidth().clamp(TR_DOWN, byte_count);
}

std::optional<std::string> tr_session::WebMediator::proxyUrl() const
{
    if (session_->is_proxy_disabled_for_session_)
    {
        return std::nullopt;
    }
    return session_->settings().proxy_url;
}

void tr_session::WebMediator::run(tr_web::FetchDoneFunc&& func, tr_web::FetchResponse&& response) const
{
    session_->run_in_session_thread(std::move(func), std::move(response));
}

time_t tr_session::WebMediator::now() const
{
    return tr_time();
}

void tr_sessionFetch(tr_session* session, tr_web::FetchOptions&& options)
{
    session->fetch(std::move(options));
}

// ---

tr_encryption_mode tr_sessionGetEncryption(tr_session const* session)
{
    TR_ASSERT(session != nullptr);

    return session->encryptionMode();
}

void tr_sessionSetEncryption(tr_session* session, tr_encryption_mode mode)
{
    TR_ASSERT(session != nullptr);
    TR_ASSERT(mode == TR_ENCRYPTION_PREFERRED || mode == TR_ENCRYPTION_REQUIRED || mode == TR_CLEAR_PREFERRED);

    session->settings_.encryption_mode = mode;
}

bool tr_sessionGetEncryptionAllowFallback(tr_session const* session)
{
    TR_ASSERT(session != nullptr);
    return session->encryptionAllowFallback();
}

void tr_sessionSetEncryptionAllowFallback(tr_session* session, bool allow)
{
    TR_ASSERT(session != nullptr);
    session->settings_.encryption_allow_fallback = allow;
}

// ---

void tr_session::onIncomingPeerConnection(tr_socket_t fd, void* vsession)
{
    auto* session = static_cast<tr_session*>(vsession);

    if (auto const incoming_info = tr_netAccept(session, fd); incoming_info)
    {
        auto const& [socket_address, sock] = *incoming_info;
        tr_logAddTrace(fmt::format("new incoming connection {} ({})", sock, socket_address.display_name()));
        session->addIncoming({ session, socket_address, sock });
    }
}

tr_session::BoundSocket::BoundSocket(
    struct event_base* evbase,
    tr_address const& addr,
    tr_port port,
    IncomingCallback cb,
    void* cb_data)
    : cb_{ cb }
    , cb_data_{ cb_data }
    , socket_{ tr_netBindTCP(addr, port, false) }
    , ev_{ event_new(evbase, socket_, EV_READ | EV_PERSIST, &BoundSocket::onCanRead, this) }
{
    if (socket_ == TR_BAD_SOCKET)
    {
        return;
    }

    tr_logAddInfo(
        fmt::format(
            fmt::runtime(_("Listening to incoming peer connections on {hostport}")),
            fmt::arg("hostport", tr_socket_address::display_name(addr, port))));
    event_add(ev_.get(), nullptr);
}

tr_session::BoundSocket::~BoundSocket()
{
    ev_.reset();

    if (socket_ != TR_BAD_SOCKET)
    {
        tr_net_close_socket(socket_);
        socket_ = TR_BAD_SOCKET;
    }
}

tr_address tr_session::bind_address(tr_address_type type) const noexcept
{
    if (type == TR_AF_INET)
    {
        // if user provided an address, use it.
        // otherwise, use any_ipv4 (0.0.0.0).
        return ip_cache_->bind_addr(type);
    }

    if (type == TR_AF_INET6)
    {
        // if user provided an address, use it.
        // otherwise, if we can determine which one to use via global_source_address(ipv6) magic, use it.
        // otherwise, use any_ipv6 (::).
        auto const source_addr = source_address(type);
        auto const default_addr = source_addr && source_addr->is_global_unicast() ? *source_addr : tr_address::any(TR_AF_INET6);
        return tr_address::from_string(settings_.bind_address_ipv6).value_or(default_addr);
    }

    TR_ASSERT_MSG(false, "invalid type");
    return {};
}

// ---

tr_variant tr_sessionGetDefaultSettings()
{
    auto ret = tr_variant::make_map();
    ret.merge(tr_rpc_server::Settings{}.save());
    ret.merge(tr_session_alt_speeds::Settings{}.save());
    ret.merge(tr_session::Settings{}.save());
    return ret;
}

tr_variant tr_sessionGetSettings(tr_session const* session)
{
    auto settings = tr_variant::make_map();
    settings.merge(session->alt_speeds_.settings().save());
    settings.merge(session->rpc_server_->settings().save());
    settings.merge(session->settings_.save());
    tr_variantDictAddInt(&settings, TR_KEY_message_level, tr_logGetLevel());
    return settings;
}

tr_variant tr_sessionLoadSettings(std::string_view const config_dir, tr_variant const* const app_defaults)
{
    // start with session defaults...
    auto settings = tr_sessionGetDefaultSettings();

    // ...app defaults (if provided) override session defaults...
    if (app_defaults != nullptr && app_defaults->holds_alternative<tr_variant::Map>())
    {
        settings.merge(*app_defaults);
    }

    // ...and settings.json (if available) override the defaults
    if (auto const filename = fmt::format("{:s}/settings.json", config_dir); tr_sys_path_exists(filename))
    {
        if (auto file_settings = tr_variant_serde::json().parse_file(filename))
        {
            libtransmission::api_compat::convert_incoming_data(*file_settings);
            settings.merge(*file_settings);
        }
    }

    return settings;
}

// ---

struct tr_session::init_data
{
    init_data(bool message_queuing_enabled_in, std::string_view config_dir_in, tr_variant const& settings_in)
        : message_queuing_enabled{ message_queuing_enabled_in }
        , config_dir{ config_dir_in }
        , settings{ settings_in }
    {
    }

    bool message_queuing_enabled;
    std::string_view config_dir;
    tr_variant const& settings;

    std::condition_variable_any done_cv;
};

tr_session* tr_sessionInit(std::string_view const config_dir, bool message_queueing_enabled, tr_variant const& client_settings)
{
    TR_ASSERT(client_settings.holds_alternative<tr_variant::Map>());

    tr_timeUpdate(time(nullptr));

    // settings order of precedence from highest to lowest:
    // - client settings
    // - previous session's values in settings.json
    // - hardcoded defaults
    auto settings = tr_sessionLoadSettings(config_dir);
    settings.merge(client_settings);

    // if logging is desired, start it now before doing more work
    if (auto const* settings_map = settings.get_if<tr_variant::Map>(); settings_map != nullptr)
    {
        if (auto const val = settings_map->value_if<bool>(TR_KEY_message_level))
        {
            tr_logSetLevel(static_cast<tr_log_level>(*val));
        }
    }

    // initialize the bare skeleton of the session object
    auto* const session = new tr_session{ config_dir, tr_variant::make_map() };
    tr_session_bandwidth_groups_read(session, config_dir);

    // run initImpl() in the libtransmission thread
    auto data = tr_session::init_data{ message_queueing_enabled, config_dir, settings };
    auto lock = session->unique_lock();
    session->run_in_session_thread([&session, &data]() { session->initImpl(data); });
    data.done_cv.wait(lock); // wait for the session to be ready

    return session;
}

void tr_session::on_now_timer()
{
    TR_ASSERT(now_timer_);
    auto const now = std::chrono::system_clock::now();

    // tr_session upkeep tasks to perform once per second
    tr_timeUpdate(std::chrono::system_clock::to_time_t(now));
    alt_speeds_.check_scheduler();

    // set the timer to kick again right after (10ms after) the next second
    auto const target_time = std::chrono::time_point_cast<std::chrono::seconds>(now) + 1s + 10ms;
    auto target_interval = target_time - now;
    if (target_interval < 100ms)
    {
        target_interval += 1s;
    }
    now_timer_->set_interval(std::chrono::duration_cast<std::chrono::milliseconds>(target_interval));
}

namespace
{
namespace queue_helpers
{
std::vector<tr_torrent*> get_next_queued_torrents(tr_torrents& torrents, tr_direction dir, size_t num_wanted)
{
    TR_ASSERT(tr_isDirection(dir));

    auto candidates = torrents.get_matching([dir](auto const* const tor) { return tor->is_queued(dir); });

    // find the best n candidates
    num_wanted = std::min(num_wanted, std::size(candidates));
    if (num_wanted < candidates.size())
    {
        std::partial_sort(
            std::begin(candidates),
            std::begin(candidates) + num_wanted,
            std::end(candidates),
            tr_torrent::CompareQueuePosition);
        candidates.resize(num_wanted);
    }

    return candidates;
}
} // namespace queue_helpers
} // namespace

size_t tr_session::count_queue_free_slots(tr_direction dir) const noexcept
{
    if (!queueEnabled(dir))
    {
        return std::numeric_limits<size_t>::max();
    }

    auto const max = queueSize(dir);
    auto const activity = dir == TR_UP ? TR_STATUS_SEED : TR_STATUS_DOWNLOAD;

    // count how many torrents are active
    auto active_count = size_t{};
    auto const stalled_enabled = queueStalledEnabled();
    auto const stalled_if_idle_for_n_seconds = static_cast<time_t>(queueStalledMinutes() * 60);
    auto const now = tr_time();
    for (auto const* const tor : torrents())
    {
        // is it the right activity?
        if (activity != tor->activity())
        {
            continue;
        }

        // is it stalled?
        if (stalled_enabled)
        {
            auto const idle_seconds = tor->idle_seconds(now);
            if (idle_seconds && *idle_seconds >= stalled_if_idle_for_n_seconds)
            {
                continue;
            }
        }

        ++active_count;

        /* if we've reached the limit, no need to keep counting */
        if (active_count >= max)
        {
            return 0;
        }
    }

    return max - active_count;
}

void tr_session::on_queue_timer()
{
    using namespace queue_helpers;

    for (auto const dir : { TR_UP, TR_DOWN })
    {
        if (!queueEnabled(dir))
        {
            continue;
        }

        auto const n_wanted = count_queue_free_slots(dir);

        for (auto* tor : get_next_queued_torrents(torrents(), dir, n_wanted))
        {
            tr_torrentStartNow(tor);

            if (queue_start_callback_ != nullptr)
            {
                queue_start_callback_(this, tor, queue_start_user_data_);
            }
        }
    }
}

// Periodically save the .resume files of any torrents whose
// status has recently changed. This prevents loss of metadata
// in the case of a crash, unclean shutdown, clumsy user, etc.
void tr_session::on_save_timer()
{
    for (auto* const tor : torrents())
    {
        tor->save_resume_file();
    }

    stats().save();
}

void tr_session::on_disk_space_timer()
{
    tr_session_pause_downloads_if_low_disk_space(this);
}

void tr_session::initImpl(init_data& data)
{
    auto lock = unique_lock();
    TR_ASSERT(am_in_session_thread());

    auto const& settings = data.settings;
    TR_ASSERT(settings.holds_alternative<tr_variant::Map>());

    tr_logAddTrace(fmt::format("tr_sessionInit: the session's top-level bandwidth object is {}", fmt::ptr(&top_bandwidth_)));

#ifndef _WIN32
    /* Don't exit when writing on a broken socket */
    (void)signal(SIGPIPE, SIG_IGN);
#endif

    tr_logSetQueueEnabled(data.message_queuing_enabled);

    blocklists_.load(blocklist_dir_, blocklist_enabled());

    tr_logAddInfo(
        fmt::format(fmt::runtime(_("Transmission version {version} starting")), fmt::arg("version", LONG_VERSION_STRING)));

    setSettings(settings, true);

    tr_utp_init(this);

    /* cleanup */
    data.done_cv.notify_one();
}

void tr_session::setSettings(tr_variant const& settings, bool force)
{
    TR_ASSERT(am_in_session_thread());
    TR_ASSERT(settings.holds_alternative<tr_variant::Map>());

    setSettings(tr_session::Settings{ settings }, force);

    // delegate loading out the other settings
    alt_speeds_.load(tr_session_alt_speeds::Settings{ settings });
    rpc_server_->load(tr_rpc_server::Settings{ settings });
}

// NOLINTNEXTLINE(cppcoreguidelines-rvalue-reference-param-not-moved): `std::swap()` also move from the parameter
void tr_session::setSettings(tr_session::Settings&& settings_in, bool force)
{
    auto const lock = unique_lock();

    std::swap(settings_, settings_in);
    auto const& new_settings = settings_;
    auto const& old_settings = settings_in;

    // the rest of the func is session_ responding to settings changes

    if (auto const& val = new_settings.log_level; force || val != old_settings.log_level)
    {
        tr_logSetLevel(val);
    }

#ifndef _WIN32
    if (auto const& val = new_settings.umask; force || val != old_settings.umask)
    {
        ::umask(val);
    }
#endif

    if (auto const& val = new_settings.cache_size_mbytes; force || val != old_settings.cache_size_mbytes)
    {
        tr_sessionSetCacheLimit_MB(this, val);
    }

    if (auto const& val = new_settings.bind_address_ipv4; force || val != old_settings.bind_address_ipv4)
    {
        ip_cache_->update_addr(TR_AF_INET);
    }
    if (auto const& val = new_settings.bind_address_ipv6; force || val != old_settings.bind_address_ipv6)
    {
        ip_cache_->update_addr(TR_AF_INET6);
    }

    if (auto const& val = new_settings.default_trackers_str; force || val != old_settings.default_trackers_str)
    {
        setDefaultTrackers(val);
    }

    bool const utp_changed = new_settings.utp_enabled != old_settings.utp_enabled;

    set_blocklist_enabled(new_settings.blocklist_enabled);

    auto local_peer_port = force && settings_.peer_port_random_on_start ? randomPort() : new_settings.peer_port;
    bool port_changed = false;
    if (force || local_peer_port_ != local_peer_port)
    {
        local_peer_port_ = local_peer_port;
        advertised_peer_port_ = local_peer_port;
        port_changed = true;
    }

    bool addr_changed = false;
    if (new_settings.tcp_enabled)
    {
        if (auto const& val = new_settings.bind_address_ipv4; force || port_changed || val != old_settings.bind_address_ipv4)
        {
            auto const addr = bind_address(TR_AF_INET);
            bound_ipv4_.emplace(event_base(), addr, local_peer_port_, &tr_session::onIncomingPeerConnection, this);
            addr_changed = true;
        }

        if (auto const& val = new_settings.bind_address_ipv6; force || port_changed || val != old_settings.bind_address_ipv6)
        {
            auto const addr = bind_address(TR_AF_INET6);
            bound_ipv6_.emplace(event_base(), addr, local_peer_port_, &tr_session::onIncomingPeerConnection, this);
            addr_changed = true;
        }
    }
    else
    {
        bound_ipv4_.reset();
        bound_ipv6_.reset();
        addr_changed = true;
    }

    if (auto const& val = new_settings.port_forwarding_enabled; force || val != old_settings.port_forwarding_enabled)
    {
        tr_sessionSetPortForwardingEnabled(this, val);
    }

    if (port_changed)
    {
        port_forwarding_->local_port_changed();
    }

    if (!udp_core_ || force || addr_changed || port_changed || utp_changed)
    {
        udp_core_ = std::make_unique<tr_session::tr_udp_core>(*this, udpPort());
    }

    // Sends out announce messages with advertisedPeerPort(), so this
    // section needs to happen here after the peer port settings changes
    if (auto const& val = new_settings.lpd_enabled; force || val != old_settings.lpd_enabled)
    {
        if (val)
        {
            lpd_ = tr_lpd::create(lpd_mediator_, event_base());
        }
        else
        {
            lpd_.reset();
        }
    }

    if (!new_settings.dht_enabled)
    {
        dht_.reset();
    }
    else if (force || !dht_ || port_changed || addr_changed || new_settings.dht_enabled != old_settings.dht_enabled)
    {
        dht_ = tr_dht::create(dht_mediator_, advertisedPeerPort(), udp_core_->socket4(), udp_core_->socket6());
    }

    if (auto const& val = new_settings.sleep_per_seconds_during_verify;
        force || val != old_settings.sleep_per_seconds_during_verify)
    {
        verifier_->set_sleep_per_seconds_during_verify(val);
    }

    // Validate proxy on startup or when proxy URL changes (async to avoid blocking startup)
    if (auto const& val = new_settings.proxy_url; val && (force || val != old_settings.proxy_url))
    {
        is_proxy_disabled_for_session_ = false; // Assume healthy, disable async if check fails
        auto const proxy_url = *val;
        std::thread(
            [this, proxy_url]()
            {
                if (!tr_web::isProxyHealthy(proxy_url))
                {
                    run_in_session_thread(
                        [this, proxy_url]()
                        {
                            tr_logAddWarn(
                                fmt::format(
                                    fmt::runtime(_("Disabling unhealthy proxy for this session: {proxy}")),
                                    fmt::arg("proxy", proxy_url)));
                            is_proxy_disabled_for_session_ = true;
                        });
                }
            })
            .detach();
    }
    else if (!val)
    {
        is_proxy_disabled_for_session_ = false;
    }

    // We need to update bandwidth if speed settings changed.
    // It's a harmless call, so just call it instead of checking for settings changes
    update_bandwidth(TR_UP);
    update_bandwidth(TR_DOWN);
}

void tr_sessionSet(tr_session* session, tr_variant const& settings)
{
    // do the work in the session thread
    auto done_promise = std::promise<void>{};
    auto done_future = done_promise.get_future();
    session->run_in_session_thread(
        [&session, &settings, &done_promise]()
        {
            session->setSettings(settings, false);
            done_promise.set_value();
        });
    done_future.wait();
}

// ---

void tr_session::Settings::fixup_from_preferred_transports()
{
    utp_enabled = false;
    tcp_enabled = false;
    for (auto const& transport : preferred_transports)
    {
        switch (transport)
        {
        case TR_PREFER_UTP:
            utp_enabled = true;
            break;
        case TR_PREFER_TCP:
            tcp_enabled = true;
            break;
        default:
            break;
        }
    }
}

void tr_session::Settings::fixup_to_preferred_transports()
{
    if (!utp_enabled)
    {
        auto const remove_it = std::remove(std::begin(preferred_transports), std::end(preferred_transports), TR_PREFER_UTP);
        preferred_transports.erase(remove_it, std::end(preferred_transports));
    }
    else if (
        std::find(std::begin(preferred_transports), std::end(preferred_transports), TR_PREFER_UTP) ==
        std::end(preferred_transports))
    {
        TR_ASSERT(std::size(preferred_transports) < preferred_transports.max_size());
        preferred_transports.emplace(std::begin(preferred_transports), TR_PREFER_UTP);
    }

    if (!tcp_enabled)
    {
        auto const remove_it = std::remove(std::begin(preferred_transports), std::end(preferred_transports), TR_PREFER_TCP);
        preferred_transports.erase(remove_it, std::end(preferred_transports));
    }
    else if (
        std::find(std::begin(preferred_transports), std::end(preferred_transports), TR_PREFER_TCP) ==
        std::end(preferred_transports))
    {
        TR_ASSERT(std::size(preferred_transports) < preferred_transports.max_size());
        preferred_transports.emplace_back(TR_PREFER_TCP);
    }
}

// ---

void tr_session::onAdvertisedPeerPortChanged()
{
    for (auto* const tor : torrents())
    {
        tr_torrentChangeMyPort(tor);
    }
}

// --- Speed limits

std::optional<Speed> tr_session::active_speed_limit(tr_direction dir) const noexcept
{
    if (tr_sessionUsesAltSpeed(this))
    {
        return alt_speeds_.speed_limit(dir);
    }

    if (is_speed_limited(dir))
    {
        return speed_limit(dir);
    }

    return {};
}

time_t tr_session::AltSpeedMediator::time()
{
    return tr_time();
}

void tr_session::AltSpeedMediator::is_active_changed(bool is_active, tr_session_alt_speeds::ChangeReason reason)
{
    auto const in_session_thread = [session = &session_, is_active, reason]()
    {
        session->update_bandwidth(TR_UP);
        session->update_bandwidth(TR_DOWN);

        if (session->alt_speed_active_changed_func_ != nullptr)
        {
            session->alt_speed_active_changed_func_(
                session,
                is_active,
                reason == tr_session_alt_speeds::ChangeReason::User,
                session->alt_speed_active_changed_func_user_data_);
        }
    };

    session_.run_in_session_thread(in_session_thread);
}

// ---

void tr_session::closeImplPart1(std::promise<void>* closed_promise, std::chrono::time_point<std::chrono::steady_clock> deadline)
{
    is_closing_ = true;

    // close the low-hanging fruit that can be closed immediately w/o consequences
    utp_timer.reset();
    verifier_.reset();
    disk_space_timer_.reset();
    save_timer_.reset();
    queue_timer_.reset();
    now_timer_.reset();
    rpc_server_.reset();
    dht_.reset();
    lpd_.reset();

    port_forwarding_.reset();
    bound_ipv6_.reset();
    bound_ipv4_.reset();

    torrent_queue().to_file();

    // Close the torrents in order of most active to least active
    // so that the most important announce=stopped events are
    // fired out first...
    auto torrents = torrents_.get_all();
    std::sort(
        std::begin(torrents),
        std::end(torrents),
        [](auto const* a, auto const* b)
        {
            auto const a_cur = a->bytes_downloaded_.ever();
            auto const b_cur = b->bytes_downloaded_.ever();
            return a_cur > b_cur; // larger xfers go first
        });

    // Save all resume files before freeing torrents.
    // This is done here so that stop_now() can skip the save during shutdown
    // (avoiding duplicate work).
    for (auto* tor : torrents)
    {
        tor->save_resume_file();
    }

    for (auto* tor : torrents)
    {
        tr_torrentFreeInSessionThread(tor);
    }
    torrents.clear();
    // ...now that all the torrents have been closed, any remaining
    // `&event=stopped` announce messages are queued in the announcer.
    // Tell the announcer to start shutdown, which sends out the stop
    // events and stops scraping.
    this->announcer_->startShutdown();
    // ...since global_ip_cache_ relies on web_ to update global addresses,
    // we tell it to stop updating before web_ starts to refuse new requests.
    // But we keep it intact for now, so that udp_core_ can continue.
    this->ip_cache_->try_shutdown();
    // ...and now that those are done, tell web_ that we're shutting
    // down soon. This leaves the `event=stopped` going but refuses any
    // new tasks.
    auto const now = std::chrono::steady_clock::now();
    auto const remaining_ms = now < deadline ? std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now) : 0ms;
    this->web_->startShutdown(remaining_ms);
    this->cache.reset();

    // recycle the now-unused save_timer_ here to wait for UDP shutdown
    TR_ASSERT(!save_timer_);
    save_timer_ = timerMaker().create([this, closed_promise, deadline]() { closeImplPart2(closed_promise, deadline); });
    save_timer_->start_repeating(50ms);
}

void tr_session::closeImplPart2(std::promise<void>* closed_promise, std::chrono::time_point<std::chrono::steady_clock> deadline)
{
    // try to keep web_ and the UDP announcer alive long enough to send out
    // all the &event=stopped tracker announces.
    // also wait for all ip cache updates to finish so that web_ can
    // safely destruct.
    if ((!web_->is_idle() || !announcer_udp_->is_idle() || !ip_cache_->try_shutdown()) &&
        std::chrono::steady_clock::now() < deadline)
    {
        announcer_->upkeep();
        return;
    }

    save_timer_.reset();

    this->announcer_.reset();
    this->announcer_udp_.reset();

    stats().save();
    peer_mgr_.reset();
    openFiles().close_all();
    tr_utp_close(this);
    this->udp_core_.reset();

    // tada we are done!
    closed_promise->set_value();
}

void tr_sessionClose(tr_session* session, double const timeout_secs)
{
    TR_ASSERT(session != nullptr);
    TR_ASSERT(!session->am_in_session_thread());

    tr_logAddInfo(
        fmt::format(fmt::runtime(_("Transmission version {version} shutting down")), fmt::arg("version", LONG_VERSION_STRING)));

    auto closed_promise = std::promise<void>{};
    auto closed_future = closed_promise.get_future();
    auto const deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds{ static_cast<int64_t>(timeout_secs * 1000.0) };
    session->run_in_session_thread([&closed_promise, deadline, session]()
                                   { session->closeImplPart1(&closed_promise, deadline); });
    closed_future.wait();

    delete session;
}

// ---

// ---

bool tr_session::allowsUTP() const noexcept
{
#ifdef WITH_UTP
    return settings_.utp_enabled;
#else
    return false;
#endif
}

// ---

void tr_session::setDefaultTrackers(std::string_view trackers)
{
    auto const oldval = default_trackers_;

    settings_.default_trackers_str = trackers;
    default_trackers_.parse(trackers);

    // if the list changed, update all the public torrents
    if (default_trackers_ != oldval)
    {
        for (auto* const tor : torrents())
        {
            if (tor->is_public())
            {
                announcer_->resetTorrent(tor);
            }
        }
    }
}

// ---

tr_bandwidth& tr_session::getBandwidthGroup(std::string_view name)
{
    auto& groups = this->bandwidth_groups_;

    for (auto const& [group_name, group] : groups)
    {
        if (group_name == name)
        {
            return *group;
        }
    }

    auto& [group_name, group] = groups.emplace_back(name, std::make_unique<tr_bandwidth>(&top_bandwidth_, true));
    return *group;
}

// ---

// ---

void tr_session::setRpcWhitelist(std::string_view whitelist) const
{
    this->rpc_server_->set_whitelist(whitelist);
}

void tr_session::useRpcWhitelist(bool enabled) const
{
    this->rpc_server_->set_whitelist_enabled(enabled);
}

bool tr_session::useRpcWhitelist() const
{
    return this->rpc_server_->is_whitelist_enabled();
}

// ---

void tr_session::verify_remove(tr_torrent const* const tor)
{
    if (verifier_)
    {
        verifier_->remove(tor->info_hash());
    }
}

void tr_session::verify_add(tr_torrent* const tor)
{
    if (verifier_)
    {
        verifier_->add(std::make_unique<tr_torrent::VerifyMediator>(tor), tor->get_priority());
    }
}

// ---
void tr_session::flush_torrent_files(tr_torrent_id_t const tor_id) const noexcept
{
    this->cache->flush_torrent(tor_id);
}

void tr_session::close_torrent_files(tr_torrent_id_t const tor_id) noexcept
{
    this->cache->flush_torrent(tor_id);
    openFiles().close_torrent(tor_id);
}

void tr_session::close_torrent_file(tr_torrent const& tor, tr_file_index_t file_num) noexcept
{
    this->cache->flush_file(tor, file_num);
    openFiles().close_file(tor.id(), file_num);
}

// ---

namespace
{
auto constexpr QueueInterval = 1s;
auto constexpr SaveInterval = 360s;
auto constexpr DiskSpaceCheckInterval = 60s;

auto makeResumeDir(std::string_view config_dir)
{
#if defined(__APPLE__) || defined(_WIN32)
    auto dir = fmt::format("{:s}/Resume"sv, config_dir);
#else
    auto dir = fmt::format("{:s}/resume"sv, config_dir);
#endif
    tr_sys_dir_create(dir.c_str(), TR_SYS_DIR_CREATE_PARENTS, 0777);
    return dir;
}

auto makeTorrentDir(std::string_view config_dir)
{
#if defined(__APPLE__) || defined(_WIN32)
    auto dir = fmt::format("{:s}/Torrents"sv, config_dir);
#else
    auto dir = fmt::format("{:s}/torrents"sv, config_dir);
#endif
    tr_sys_dir_create(dir.c_str(), TR_SYS_DIR_CREATE_PARENTS, 0777);
    return dir;
}

auto makeBlocklistDir(std::string_view config_dir)
{
    auto dir = fmt::format("{:s}/blocklists"sv, config_dir);
    tr_sys_dir_create(dir.c_str(), TR_SYS_DIR_CREATE_PARENTS, 0777);
    return dir;
}
} // namespace

tr_session::tr_session(std::string_view config_dir, tr_variant const& settings_dict)
    : config_dir_{ config_dir }
    , resume_dir_{ makeResumeDir(config_dir) }
    , torrent_dir_{ makeTorrentDir(config_dir) }
    , blocklist_dir_{ makeBlocklistDir(config_dir) }
    , session_thread_{ tr_session_thread::create() }
    , timer_maker_{ std::make_unique<libtransmission::EvTimerMaker>(event_base()) }
    , settings_{ settings_dict }
    , session_id_{ tr_time }
    , peer_mgr_{ tr_peerMgrNew(this), &tr_peerMgrFree }
    , rpc_server_{ std::make_unique<tr_rpc_server>(this, tr_rpc_server::Settings{ settings_dict }) }
    , now_timer_{ timer_maker_->create([this]() { on_now_timer(); }) }
    , queue_timer_{ timer_maker_->create([this]() { on_queue_timer(); }) }
    , save_timer_{ timer_maker_->create([this]() { on_save_timer(); }) }
    , disk_space_timer_{ timer_maker_->create([this]() { on_disk_space_timer(); }) }
{
    now_timer_->start_repeating(1s);
    queue_timer_->start_repeating(QueueInterval);
    save_timer_->start_repeating(SaveInterval);
    disk_space_timer_->start_repeating(DiskSpaceCheckInterval);
}

void tr_session::addIncoming(tr_peer_socket&& socket)
{
    tr_peerMgrAddIncoming(peer_mgr_.get(), std::move(socket));
}

void tr_session::addTorrent(tr_torrent* tor)
{
    tor->init_id(torrents().add(tor));
    torrent_queue_.add(tor->id());

    tr_peerMgrAddTorrent(peer_mgr_.get(), tor);
}
