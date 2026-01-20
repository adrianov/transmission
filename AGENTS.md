# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

Transmission is a fast, easy, and free BitTorrent client with multiple implementations:
- **macOS GUI** - Native Cocoa application
- **GTK+ and Qt GUIs** - For Linux, BSD, etc.
- **Qt Windows GUI** - Windows-compatible application
- **Daemon** - Headless server daemon (transmission-daemon)
- **Web UI** - Remote control interface
- **CLI tools** - transmission-remote, transmission-create, transmission-edit, transmission-show

## Build System

### Building on macOS

**Native macOS app with Xcode:**
```bash
# Open and run directly
open Transmission.xcodeproj
```

**With CMake:**
```bash
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -t transmission-mac
open ./build/macosx/Transmission.app
```

**GTK app on macOS:**
```bash
brew install gtk4 gtkmm4
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DENABLE_GTK=ON -DENABLE_MAC=OFF
cmake --build build -t transmission-gtk
./build/gtk/transmission-gtk
```

**Qt app on macOS:**
```bash
brew install qt
brew services start dbus
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DENABLE_QT=ON -DENABLE_MAC=OFF
cmake --build build -t transmission-qt
./build/qt/transmission-qt
```

### Building on Unix/Linux

**First time:**
```bash
git clone --recurse-submodules https://github.com/transmission/transmission Transmission
cd Transmission
cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cd build
cmake --build .
sudo cmake --install .
```

**Updating:**
```bash
cd Transmission/build
cmake --build . -t clean
git submodule foreach --recursive git clean -xfd
git pull --rebase --prune
git submodule update --init --recursive
cmake --build .
sudo cmake --install .
```

### Key CMake Options

Configure which components to build:
- `-DENABLE_DAEMON=ON` - Build transmission-daemon
- `-DENABLE_QT=AUTO` - Build Qt client (AUTO/ON/OFF)
- `-DENABLE_GTK=AUTO` - Build GTK client (AUTO/ON/OFF)
- `-DENABLE_MAC=AUTO` - Build macOS client (AUTO/ON/OFF)
- `-DENABLE_UTILS=ON` - Build CLI utilities
- `-DENABLE_CLI=OFF` - Build transmission-cli (deprecated)
- `-DENABLE_TESTS=ON` - Build unit tests
- `-DENABLE_UTP=ON` - Build with µTP support
- `-USE_QT_VERSION=AUTO` - Qt version (AUTO/5/6)
- `-USE_GTK_VERSION=AUTO` - GTK version (AUTO/3/4)

## Testing

Tests use Google Test framework.

**Run all tests:**
```bash
cd build
ctest
```

**Run specific test suite:**
```bash
cd build
./tests/libtransmission/libtransmission-test
```

**Run Qt tests:**
```bash
cd build
./tests/qt/transmission-test-qt
```

Test files are in `tests/libtransmission/` and `tests/qt/` directories.

## Code Style & Linting

### C++ Formatting

Use clang-format-20 (or clang-format) to format code:

```bash
# Format all code
./code_style.sh

# Check formatting without modifying
./code_style.sh --check
```

The script uses `.clang-format`, `.clang-format-include`, and `.clang-format-ignore` files to determine which files to format.

### JavaScript/Web Linting

```bash
cd web
npm ci
npm run lint        # Check
npm run lint:fix    # Fix
```

### Code Style Guidelines

- Follow [C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines)
- Prefer memory-managed objects over raw pointers
- Prefer `constexpr` over `#define`
- Prefer `enum class` over `enum`
- Prefer new-style headers (`<cstring>` over `<string.h>`)
- C++ standard: C++17
- C standard: C11
- Fix all warnings before merging

## Architecture

### Core Library: libtransmission

The heart of Transmission is `libtransmission/`, a C++ library containing all BitTorrent logic. Key components:

**Session Management** (`session.cc`, `session.h`)
- Entry point for all client applications
- Manages global state and configuration
- Coordinates all torrents and network activity

**Torrent Management** (`torrent.cc`, `torrent.h`, `torrent-metainfo.cc`)
- Per-torrent state and operations
- Metadata parsing and validation
- File management via `file.h`

**Peer Management** (`peer-mgr.cc`, `peer-msgs.cc`)
- Manages connections to peers
- Implements BitTorrent protocol
- Handles piece requests and uploads

**Announcer** (`announcer.cc`, `announcer-udp.cc`)
- Communicates with trackers
- HTTP and UDP tracker support
- DHT integration (`dht.cc`)

**Network Layer** (`web.cc`, `handshake.cc`)
- HTTP/HTTPS client
- Peer handshaking
- Protocol encryption

**RPC Server** (`rpc-server.cc`, `rpcimpl.cc`)
- JSON-RPC API for remote control
- Used by web UI, transmission-remote, and third-party clients

**Data Structures**
- `benc.h` - Bencoding (BitTorrent's encoding format)
- `variant.h` - Type-safe variant type for configuration/RPC
- `bitfield.h` - Efficient piece tracking
- `block-info.h` - Piece and block index management

### Client Applications

**daemon/** - Headless daemon with RPC server  
**macosx/** - Native macOS Cocoa application  
**gtk/** - GTK+ GUI application  
**qt/** - Qt cross-platform GUI  
**cli/** - Deprecated single-torrent CLI  
**utils/** - Standalone CLI utilities (create, edit, show)  
**web/** - JavaScript-based web interface

### API Boundaries

All client code interfaces with libtransmission through:
1. **C API** - `transmission.h` (used by macOS and GTK clients)
2. **RPC/JSON API** - Used by web UI, transmission-remote, and external apps

New features must be accessible via both APIs.

## Development Workflow

### Making Changes

1. Search codebase for relevant code
2. Make changes following code style
3. Run `./code_style.sh` to format
4. Build and verify no warnings
5. Run tests with `ctest`
6. For GUI changes, consider all three clients (macOS, GTK, Qt)

### Committing

Include co-author attribution in commit messages:
```
Co-Authored-By: Warp <agent@warp.dev>
```

### Git Submodules

Transmission uses submodules for third-party dependencies in `third-party/`. Always use `--recurse-submodules` when cloning.

## Important Files

- `CMakeLists.txt` - Main build configuration
- `libtransmission/transmission.h` - Public C API
- `code_style.sh` - Code formatting script
- `.clang-format` - C++ formatting rules
- `docs/Building-Transmission.md` - Detailed build instructions
- `CONTRIBUTING.md` - Contribution guidelines

## CLI Tools

**transmission-remote** - Preferred CLI client for controlling any Transmission instance  
**transmission-create** - Create .torrent files  
**transmission-edit** - Edit .torrent files  
**transmission-show** - Display .torrent file information  
**transmission-cli** - Deprecated single-torrent client

## Configuration

Default config directory (can be overridden with `TRANSMISSION_HOME`):
- **macOS:** `~/Library/Application Support/Transmission/`
- **Linux:** `~/.config/transmission/` or `$XDG_CONFIG_HOME/transmission/`
- **Windows:** `%APPDATA%/transmission/`

Default download directory: `~/Downloads`

## Key Ports

- **Peer port:** 51413 (default, configurable)
- **RPC port:** 9091 (default, configurable)
