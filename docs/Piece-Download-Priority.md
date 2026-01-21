# Piece Download Priority

This document describes how Transmission prioritizes which pieces to download, particularly in sequential download mode.

## Overview

When downloading a torrent, Transmission uses a wishlist system to determine which pieces to request from peers. The order in which pieces are requested affects download efficiency and user experience, especially for media files that users may want to preview while downloading.

## Priority Criteria

Pieces are sorted and requested based on the following criteria, in order of importance:

### 1. Piece Priority (Highest First)

Each piece inherits priority from the files it belongs to:
- **High** (`TR_PRI_HIGH`) - Requested first
- **Normal** (`TR_PRI_NORMAL`) - Default priority
- **Low** (`TR_PRI_LOW`) - Requested last

Additionally, "edge pieces" (pieces at file boundaries) automatically receive high priority to enable earlier access to incomplete files.

### 2. File Order (Alphabetical)

Within the same priority level, pieces are ordered by their associated file's alphabetical position. This is particularly useful for:
- TV series episodes (e.g., "Episode 01.mkv" downloads before "Episode 02.mkv")
- Multi-part archives
- Any content where alphabetical order matches logical viewing/usage order

The alphabetical comparison is case-insensitive and handles special cases:
- Files with the same extension where one name is a prefix of another are ordered by length (shorter first)
- Directory structure is considered (files in earlier directories come first)

### 3. File Tail Priority (Last 20 MB)

Pieces located in the last 20 MB of a file are prioritized over pieces earlier in the same file. This optimization benefits video playback:

- **Video container indexes**: Many video formats (MP4, MKV, AVI) store seeking indexes at the end of the file
- **Subtitle tracks**: Often located near the end of container files
- **Audio tracks**: May be stored after the video stream

By downloading the file tail early, video players can:
- Display accurate duration and progress
- Enable seeking functionality sooner
- Access all audio/subtitle tracks

For files smaller than 20 MB, all pieces are considered "tail" pieces.

### 4. Piece Number (Sequential Order)

Finally, pieces are ordered by their piece index. Combined with the file ordering above, this ensures sequential playback within each file.

## Sequential vs Random Download

### Sequential Download Mode

When enabled (`is_sequential_download()`), the wishlist respects file boundaries:
- Completes one file before moving to the next (within the same priority)
- Ideal for media playback and ordered content consumption
- May reduce swarm efficiency compared to random piece selection

### Random Download Mode (Default)

Without sequential mode:
- Pieces are still sorted by the criteria above
- But the system may request pieces from multiple files simultaneously
- Generally more efficient for swarm health and download speed

## Implementation Details

The piece selection logic is implemented in:
- `libtransmission/peer-mgr-wishlist.cc` - Wishlist candidate sorting
- `libtransmission/torrent.cc` - File ordering and tail detection (`is_piece_in_file_tail()`)

### Key Functions

```cpp
// Determines if a piece is in the last 20 MB of any file it belongs to
bool tr_torrent::is_piece_in_file_tail(tr_piece_index_t piece) const noexcept;

// Returns the alphabetical file index for a piece
tr_piece_index_t tr_torrent::file_index_for_piece(tr_piece_index_t piece) const noexcept;

// Recalculates file ordering when wanted files change
void tr_torrent::recalculate_file_order();
```

### Sort Key

The internal sort key for piece candidates is:
```cpp
std::tuple{ -priority, file_index, !is_in_priority_file, !is_in_file_tail, piece }
```

This creates the ordering: high priority → alphabetical file → priority files → tail pieces → sequential pieces.

### Priority Files (Disc Index Files)

For DVD and Blu-ray disc structures, index files are prioritized to enable proper playback:

- **DVD**: `.ifo` and `.bup` files (disc navigation and backup)
- **Blu-ray**: `index.bdmv` and `movieobject.bdmv` (disc index and menu)

These files are downloaded before the actual video content (VOB/M2TS) to ensure players can properly navigate the disc structure.

## User-Facing Settings

- **File Priority**: Set via the UI or RPC for individual files
- **Sequential Download**: Toggle per-torrent to enable ordered downloading
- **File Selection**: Unwanted files are excluded from the wishlist entirely

## See Also

- [Editing-XIB-Files.md](Editing-XIB-Files.md) - For macOS UI modifications
- [rpc-spec.md](rpc-spec.md) - RPC methods for setting priorities
