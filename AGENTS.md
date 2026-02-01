# AGENTS.md

This file provides guidance for agentic coding agents working with the Transmission codebase.

## Build Commands

**Clean build from scratch:**
```bash
cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DENABLE_TESTS=ON
cmake --build build -j$(nproc)    # Linux
cmake --build build -j$(sysctl -n hw.ncpu)    # macOS
```

**Rebuild after changes:**
```bash
cmake --build build -j$(nproc) 2>&1 | tail -5
```

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

**Run single test (GoogleTest syntax):**
```bash
cd build
./tests/libtransmission/libtransmission-test --gtest_filter=TestSuite.TestCase
# Examples:
./tests/libtransmission/libtransmission-test --gtest_filter=AnnounceListTest.canAdd
./tests/libtransmission/libtransmission-test --gtest_filter=SessionTest.*
./tests/libtransmission/libtransmission-test --gtest_filter=*canAdd
```

**List all available tests:**
```bash
./tests/libtransmission/libtransmission-test --gtest_list_tests
```

**Run Qt tests:**
```bash
cd build
./tests/qt/transmission-test-qt
```

**Build specific target:**
```bash
cmake --build build -t transmission-mac    # macOS
cmake --build build -t transmission-daemon
cmake --build build -t transmission-gtk
cmake --build build -t transmission-qt
```

**macOS convenience script:** `bin/build-mac` configures with Ninja/Release, builds the transmission-mac target, and opens the app (or build folder) in Finder.

**IINA watch_later comparison:** `bin/compare-iina-watch-later [watch_later_dir] [downloads_dir]` lists how many files under Downloads have IINA watch state (same path normalization and MD5 as IINAWatchHelper). **Single-file check:** `bin/check-iina-watch-later <file_path> [watch_later_dir]` prints normalized path, expected hash, and whether an IINA watch_later file exists for that path. Formula: `WATCH_LATER_FILENAME = UPPERCASE( MD5( UTF8( NORMALIZED_FULL_PATH ) ) )` — 32-char hex in `~/Library/Application Support/com.colliderli.iina/watch_later/`.

## Lint Commands

**Check C++ formatting:**
```bash
./code_style.sh --check
```

**Apply C++ formatting:**
```bash
./code_style.sh
# Or for specific files:
clang-format -i path/to/file.cc path/to/file.h
```

**Web linting (web/ directory):**
```bash
cd web
npm ci
npm run lint              # Check
npm run lint:fix          # Fix
```

## Code Style Guidelines

### Imports and Headers

- Prefer new-style C++ headers: `<cstring>`, `<cstdint>`, `<vector>` over `<string.h>`, `<stdint.h>`
- Prefer local includes with double quotes: `"libtransmission/transmission.h"`
- Use `#pragma once` instead of include guards in headers
- Sort using declarations alphabetically (enforced by clang-format)

### Types and Constants

- C++ standard: C++17, C standard: C11
- Prefer `enum class` over `enum`
- Prefer `constexpr` over `#define` for constants
- Use `uint64_t`, `int64_t` from `<cstdint>` for fixed-width integers
- Use `size_t`, `time_t` for platform-dependent sizes
- Use `std::string_view` for read-only string parameters
- Use `std::optional` instead of pointer-or-sentinel patterns

### Naming Conventions

- **Classes/structs:** PascalCase (`class TorrentManager`, `struct tr_torrent`)
- **Functions/Methods:** camelCase (`void loadFiles()`, `int getPort()`)
- **Variables:** camelCase for local members (`bool isValid;`), trailing underscore for private members (`bool paused_;`)
- **Constants:** UPPER_SNAKE_CASE for macros (rarely needed due to `constexpr`)
- **Test fixtures:** PascalCase with `Test` suffix (`class VariantTest`, `class RenameTest`)
- **Test cases:** TEST_F(TestFixture, TestCase) pattern (`TEST_F(VariantTest, getType)`)

### Memory Management

- Prefer memory-managed objects (`std::unique_ptr`, `std::shared_ptr`) over raw pointers
- Use `[[nodiscard]]` attribute on functions that return values that should be used
- Use `noexcept` on functions that cannot throw exceptions

### Error Handling

- Use `tr_error` struct from `<libtransmission/error.h>` for errors
- Error codes are int values, messages are `std::string` or `std::string_view`
- Use `tr_error::set()` or `tr_error::set_from_errno()` to set errors
- Check error state with boolean conversion or `has_value()`

### Formatting

- 4-space indentation (no tabs)
- 128 column limit
- clang-format enforces: `AlignAfterOpenBracket: AlwaysBreak`, `PointerAlignment: Left`
- Use `const` for variables that don't change
- Place `*` on left side of pointer: `Type* pointer` (not `Type *pointer`)
- Place `&` on left side of reference: `Type& reference` (not `Type &reference`)

### General Guidelines

- Follow C++ Core Guidelines: https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines
- **Documentation**: Before starting a task, search the `docs/` directory for relevant documentation (e.g., `docs/*.md` files). This often provides critical context on existing features and implementation rules (e.g., `Human-Friendly-Titles.md`). After making changes that affect documented behavior or add new features, update the relevant `docs/*.md` files if appropriate.
- Fix all warnings before merging code
- Address compiler warnings that occur during the build process immediately, even if they don't prevent compilation
- Use standard library containers (`std::vector`, `std::map`) over custom implementations
- Prefer dependency injection or other decoupling methods for testability
- KISS principle: Try simpler approaches first in complex codebase
- New features must be accessible via both C API (`transmission.h`) and RPC/JSON API
- **File size**: Refactor files of 1000+ lines so they have fewer than 1000 lines (extract modules or classes, remove unused/duplicate code as needed).

### API Boundaries

- **libtransmission** is the core C++ library
- macOS and GTK clients use C API from `transmission.h`
- Web UI, transmission-remote, and external apps use RPC/JSON API
- All new features must work through both APIs

## macOS Development Guidelines

### Objective-C++ Code Style

- macOS client code is in `macosx/` directory using Objective-C++ (`.mm` files)
- Follow Objective-C naming conventions: methods use camelCase, classes use PascalCase
- Use `@property` declarations in headers, synthesize in implementation
- Prefer `NSString*` over C strings for path handling
- Use Foundation collections: `NSArray`, `NSDictionary`, `NSSet` for Objective-C code
- Use `dispatch_once` for thread-safe static initialization
- Use `objc_getAssociatedObject`/`objc_setAssociatedObject` for associating data with UI elements when needed

### File Association Patterns

- **Associated file handling**: When files have companion files (e.g., `.cue` files for audio files), centralize the association logic in the `Torrent` class
- **Example pattern**: For `.cue` file associations:
  - `cueFilePathForAudioPath:` - Finds companion `.cue` file for an audio file path
  - `cueFilePathForFolder:` - Finds `.cue` file within a folder (for album directories)
  - `tooltipPathForItemPath:type:folder:` - Centralized method to determine the correct path to display in tooltips
- Keep file association logic in the data model (`Torrent` class), not in UI components

### UI Component Architecture

- **`Torrent` class**: Central data model containing torrent state and file operations
- **`TorrentTableView`**: Manages table view UI and user interactions (play buttons, file opening)
- **`FileNameCellView`**: Displays individual file/folder names and tooltips
- **DRY Principle**: When multiple UI components need the same logic (e.g., determining tooltip paths, finding associated files), implement it once in the `Torrent` class and have UI components call those methods
- UI components should access `Torrent` through `FileListNode.torrent` property
- Avoid duplicating file path resolution or association logic across UI components
