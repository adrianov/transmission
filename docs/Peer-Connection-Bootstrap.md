# Peer Connection Bootstrap

This document describes how Transmission establishes peer connections for newly added torrents, especially when many torrents are active and global connection limits are nearly full.

## Problem

When adding a new download while hundreds of other torrents are running, the UI can show **"Downloading from 0 of 0 peers"** for several seconds even though the tracker has returned 10–20 peers. Known peers sit in the connectable pool but no TCP/uTP connections are opened yet.

## Root Causes

### 1. Peers are queued, not connected immediately

Tracker responses call `tr_peerMgrAddPex()`, which only adds addresses to each swarm's `connectable_pool`. Outbound connections are created later by `tr_peerMgr::make_new_peer_connections()` during the 500 ms **bandwidth pulse**.

**On app restart**, resume peers are loaded during torrent init **before** the swarm is running, so the tracker hook does not run for them. Bootstrap on `on_torrent_started()` covers that case using peers already restored from the `.resume` file.

### 2. Global outbound throttle

At most **9 outbound handshakes per 500 ms pulse** (`MaxConnectionsPerPulse`) are attempted across **all** torrents. With hundreds of swarms competing, a new torrent waits its turn in a cached candidate list (up to ~2 seconds TTL).

### 3. Near-limit hard stop (fixed)

Previously, when connected peers reached **95% of the global limit**, **no** outbound connections were attempted. With a limit of 200 peers, nothing new could connect at 190+ peers—even for torrents with zero connections.

### 4. Weak bootstrap priority

Candidate scoring preferred recently started torrents, but not strongly enough when many other downloads were also active.

### 5. Seeding torrents crowding out downloads (fixed)

With many seeding torrents, three things blocked new downloads:

- "Downloading vs seeding" was a low tie-breaker, so seeding peers that were tried less recently won candidate slots.
- Near the outbound cap, empty **seeding** swarms could still connect, while downloads that already had one or two peers could not.
- Over the global limit, peers were culled by recent piece activity first. A just-connected download peer has none yet, so it was closed before active seeding peers.

## Behavior After Bootstrap Improvements

Transmission now follows patterns similar to libtorrent's [`torrent_connect_boost`](https://www.libtorrent.org/reference-Settings.html):

| Mechanism | Description |
|-----------|-------------|
| **Tracker connect boost** | On the **first tracker peer list** for a swarm with **zero connected peers**, up to **10** outbound connections start **immediately** (not waiting for the next pulse). |
| **Start connect boost** | When a **downloading torrent starts** (including after app restart) with resume peers in the pool but **zero connected peers**, the same immediate bootstrap runs. |
| **Candidate cache invalidation** | Adding peers to a zero-peer swarm within 60 s of start clears the cached outbound candidate list so the next pulse rebuilds with the new addresses. |
| **Downloads first** | Every downloading torrent's candidates rank ahead of every seeding torrent's candidates. |
| **Bootstrap scoring** | Among torrents in the same state, swarms with **no connected peers** rank ahead of swarms that already have connections. |
| **Near-limit exception** | When at the outbound cap, **downloading** torrents still connect; seeding torrents wait until slots free up. |
| **Seeding peers culled first** | When over the global limit, seeding peers are closed before any download peer, so downloads keep the slots they take. |

Existing behavior is unchanged for:

- **Incoming connections** — seeding torrents still leave about 5% of the global limit free for incoming peers (ticket #2609). Downloads may use that space.
- **Per-torrent peer limits** — enforced after connections succeed.

## Connection Timeline (typical new download)

```mermaid
sequenceDiagram
    participant User
    participant Torrent
    participant Announcer
    participant PeerMgr
    participant Peer

    User->>Torrent: App restart / torrent start
    Torrent->>PeerMgr: on_torrent_started (resume peers already in pool)
    PeerMgr->>Peer: bootstrap up to 10 connections immediately
    Torrent->>Announcer: started announce
    Announcer->>PeerMgr: tracker peers (may add more)
    Peer-->>PeerMgr: handshake complete
    Note over Torrent: "Downloading from N of M peers"
    loop every 500 ms
        PeerMgr->>Peer: up to 9 more outbound attempts (all torrents)
    end
```

## Tuning

| Setting | Default | Effect |
|---------|---------|--------|
| `peer-limit-global` | 200 | Max connected peers session-wide |
| `peer-limit-per-torrent` | 50 | Max peers per torrent |
| Torrent priority (`high` / `normal` / `low`) | normal | Higher priority torrents win candidate scoring |

Every 10 seconds, a downloading torrent records its combined upload and download speed with different numbers of peers. It can then lower its peer limit to the number of peers that gave the best speed. That lower limit only applies while the torrent downloads at **1 MB/s or more**. Below that speed, the torrent uses its full `peer-limit-per-torrent`, so it can keep looking for faster peers.

For large libraries (100+ torrents), consider:

- Raising `peer-limit-global` if your router and OS tolerate it (many users run 400–800 on libtorrent-based clients).
- Setting **high priority** on torrents you add for immediate watching.
- Ensuring the **listening port is open** — incoming peers bypass the outbound throttle entirely.

## Implementation Files

- `libtransmission/peer-mgr-connect.h` — bootstrap constants and API
- `libtransmission/peer-mgr-connect-score.inc` — candidate scoring (included from `peer-mgr.cc`)
- `libtransmission/peer-mgr-connect-candidates.inc` — candidate selection and tracker bootstrap
- `libtransmission/peer-mgr.cc` — `tr_peerMgrAddPex()` tracker boost hook, bandwidth pulse scheduling

## Related Documentation

- [Piece Download Priority](Piece-Download-Priority.md) — piece request ordering after peers connect
- [Why Are My Speeds So Slow](Why-Are-My-Speeds-So-Slow.md) — general network tuning
