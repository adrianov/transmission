// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.
//
// Fragment included from session.h: inner mediator/socket classes of tr_session.

#ifndef __TRANSMISSION__
#error only libtransmission should #include this header.
#endif

    class BoundSocket
    {
    public:
        using IncomingCallback = void (*)(tr_socket_t, void*);
        BoundSocket(struct event_base* base, tr_address const& addr, tr_port port, IncomingCallback cb, void* cb_data);
        BoundSocket(BoundSocket&&) = delete;
        BoundSocket(BoundSocket const&) = delete;
        BoundSocket operator=(BoundSocket&&) = delete;
        BoundSocket operator=(BoundSocket const&) = delete;
        ~BoundSocket();

    private:
        static void onCanRead(evutil_socket_t fd, short /*what*/, void* vself)
        {
            auto* const self = static_cast<BoundSocket*>(vself);
            self->cb_(fd, self->cb_data_);
        }

        IncomingCallback cb_;
        void* cb_data_;
        tr_socket_t socket_ = TR_BAD_SOCKET;
        libtransmission::evhelpers::event_unique_ptr ev_;
    };

    class AltSpeedMediator final : public tr_session_alt_speeds::Mediator
    {
    public:
        explicit AltSpeedMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        void is_active_changed(bool is_active, tr_session_alt_speeds::ChangeReason reason) override;

        [[nodiscard]] time_t time() override;

        ~AltSpeedMediator() noexcept override = default;

    private:
        tr_session& session_;
    };

    class AnnouncerUdpMediator final : public tr_announcer_udp::Mediator
    {
    public:
        explicit AnnouncerUdpMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        ~AnnouncerUdpMediator() noexcept override = default;

        void sendto(void const* buf, size_t buflen, sockaddr const* addr, socklen_t addrlen) override
        {
            session_.udp_core_->sendto(buf, buflen, addr, addrlen);
        }

        [[nodiscard]] std::optional<tr_address> announce_ip() const override
        {
            if (!session_.useAnnounceIP())
            {
                return {};
            }

            return tr_address::from_string(session_.announceIP());
        }

    private:
        tr_session& session_;
    };

    class DhtMediator : public tr_dht::Mediator
    {
    public:
        explicit DhtMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        ~DhtMediator() noexcept override = default;

        [[nodiscard]] std::vector<tr_torrent_id_t> torrents_allowing_dht() const override;

        [[nodiscard]] tr_sha1_digest_t torrent_info_hash(tr_torrent_id_t id) const override;

        [[nodiscard]] std::string_view config_dir() const override
        {
            return session_.config_dir_;
        }

        [[nodiscard]] libtransmission::TimerMaker& timer_maker() override
        {
            return session_.timerMaker();
        }

        void add_pex(tr_sha1_digest_t const& info_hash, tr_pex const* pex, size_t n_pex) override;

    private:
        tr_session& session_;
    };

    class PortForwardingMediator final : public tr_port_forwarding::Mediator
    {
    public:
        explicit PortForwardingMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        [[nodiscard]] tr_address incoming_peer_address() const override
        {
            return session_.bind_address(TR_AF_INET);
        }

        [[nodiscard]] tr_port advertised_peer_port() const override
        {
            return session_.advertisedPeerPort();
        }

        [[nodiscard]] tr_port local_peer_port() const override
        {
            return session_.localPeerPort();
        }

        [[nodiscard]] libtransmission::TimerMaker& timer_maker() override
        {
            return session_.timerMaker();
        }

        void on_port_forwarded(tr_port public_port) override
        {
            if (session_.advertised_peer_port_ != public_port)
            {
                session_.advertised_peer_port_ = public_port;
                session_.onAdvertisedPeerPortChanged();
            }
        }

    private:
        tr_session& session_;
    };

    class QueueMediator final : public tr_torrent_queue::Mediator
    {
    public:
        explicit QueueMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        [[nodiscard]] std::string config_dir() const override
        {
            return session_.configDir();
        }

        [[nodiscard]] std::string store_filename(tr_torrent_id_t id) const override;

    private:
        tr_session& session_;
    };

    class WebMediator final : public tr_web::Mediator
    {
    public:
        explicit WebMediator(tr_session* session) noexcept
            : session_{ session }
        {
        }

        [[nodiscard]] std::optional<std::string> cookieFile() const override;
        [[nodiscard]] std::optional<std::string> bind_address_V4() const override;
        [[nodiscard]] std::optional<std::string> bind_address_V6() const override;
        [[nodiscard]] std::optional<std::string_view> userAgent() const override;
        [[nodiscard]] size_t clamp(int torrent_id, size_t byte_count) const override;
        [[nodiscard]] std::optional<std::string> proxyUrl() const override;
        [[nodiscard]] time_t now() const override;
        // runs the tr_web::fetch response callback in the libtransmission thread
        void run(tr_web::FetchDoneFunc&& func, tr_web::FetchResponse&& response) const override;

    private:
        tr_session* const session_;
    };

    class LpdMediator final : public tr_lpd::Mediator
    {
    public:
        explicit LpdMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        [[nodiscard]] tr_address bind_address(tr_address_type type) const override
        {
            return session_.bind_address(type);
        }

        [[nodiscard]] tr_port port() const override
        {
            return session_.advertisedPeerPort();
        }

        [[nodiscard]] bool allowsLPD() const override
        {
            return session_.allowsLPD();
        }

        [[nodiscard]] libtransmission::TimerMaker& timerMaker() override
        {
            return session_.timerMaker();
        }

        [[nodiscard]] std::vector<TorrentInfo> torrents() const override;

        bool onPeerFound(std::string_view info_hash_str, tr_address address, tr_port port) override;

        void setNextAnnounceTime(std::string_view info_hash_str, time_t announce_after) override;

    private:
        tr_session& session_;
    };

    class IPCacheMediator final : public tr_ip_cache::Mediator
    {
    public:
        explicit IPCacheMediator(tr_session& session) noexcept
            : session_{ session }
        {
        }

        void fetch(tr_web::FetchOptions&& options) override
        {
            session_.fetch(std::move(options));
        }

        [[nodiscard]] std::string_view settings_bind_addr(tr_address_type type) override
        {
            switch (type)
            {
            case TR_AF_INET:
                return session_.settings_.bind_address_ipv4;
            case TR_AF_INET6:
                return session_.settings_.bind_address_ipv6;
            default:
                TR_ASSERT_MSG(false, "Invalid type");
                return {};
            }
        }

        [[nodiscard]] libtransmission::TimerMaker& timer_maker() override
        {
            return session_.timerMaker();
        }

    private:
        tr_session& session_;
    };

    // UDP connectivity used for the DHT and µTP
    class tr_udp_core
    {
    public:
        tr_udp_core(tr_session& session, tr_port udp_port);
        ~tr_udp_core();

        tr_udp_core(tr_udp_core const&) = delete;
        tr_udp_core(tr_udp_core&&) = delete;
        tr_udp_core& operator=(tr_udp_core const&) = delete;
        tr_udp_core& operator=(tr_udp_core&&) = delete;

        void sendto(void const* buf, size_t buflen, struct sockaddr const* to, socklen_t tolen) const;

        [[nodiscard]] constexpr auto socket4() const noexcept
        {
            return udp4_socket_;
        }

        [[nodiscard]] constexpr auto socket6() const noexcept
        {
            return udp6_socket_;
        }

    private:
        tr_port const udp_port_;
        tr_session& session_;
        tr_socket_t udp4_socket_ = TR_BAD_SOCKET;
        tr_socket_t udp6_socket_ = TR_BAD_SOCKET;
        libtransmission::evhelpers::event_unique_ptr udp4_event_;
        libtransmission::evhelpers::event_unique_ptr udp6_event_;
    };
