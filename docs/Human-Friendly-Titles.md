# Human-Friendly Torrent Titles

Transmission displays human-friendly titles instead of raw technical torrent names in the main window and provides quick Play buttons for media torrents.

## Overview

Technical torrent names often contain release information that makes them hard to read:

```
Major.Grom.Igra.protiv.pravil.S01.2025.WEB-DL.HEVC.2160p.SDR.ExKinoRay
```

The human-friendly title extracts the meaningful parts:

```
Major Grom Igra protiv pravil - Season 1 (2025) #2160p
```

## Title Transformation Rules

### 1. File Extension Removal

Common video file extensions are stripped:
- `.mkv`, `.avi`, `.mp4`, `.mov`, `.wmv`, `.flv`, `.webm`, `.m4v`, `.torrent`

### 2. Resolution Extraction

Resolution is extracted and normalized:
- `2160p`, `1080p`, `720p`, `480p` - kept as-is
- `4K`, `UHD` - normalized to `2160p`
- Merged patterns like `BDRip1080p` are split to `BDRip 1080p` before processing

### 3. Season/Episode Detection

Season markers are converted to readable format:
- `S01` → `Season 1`
- `S01E05` → `Season 1` (episode number removed from title)
- `S12` → `Season 12`

### 4. Year Extraction

Four-digit years (1900-2099) are preserved in the output.

### 5. Date Detection

Date patterns in `YY.MM.DD` format are preserved (common in dated content):
- `25.04.14` stays as `25.04.14`

### 6. Technical Tags Removal

The following technical tags are filtered out:

**Video Sources:**
- `WEB-DL`, `WEBDL`, `WEBRip`, `BDRip`, `BluRay`, `HDRip`, `DVDRip`, `HDTV`

**Video Codecs:**
- `HEVC`, `H264`, `H.264`, `H265`, `H.265`, `x264`, `x265`, `AVC`, `10bit`

**Audio Codecs:**
- `AAC`, `AC3`, `DTS`, `Atmos`, `TrueHD`, `FLAC`, `EAC3`

**HDR Formats:**
- `SDR`, `HDR`, `HDR10`, `DV`, `DoVi`

**Streaming Sources:**
- `AMZN`, `NF`, `DSNP`, `HMAX`, `PCOK`, `ATVP`, `APTV`

**Release Info:**
- `ExKinoRay`, `RuTracker`, `LostFilm`, `MP4`, `IMAX`, `REPACK`, `PROPER`, `EXTENDED`, `UNRATED`, `REMUX`

### 7. Separator Normalization

- Dots (`.`) and underscores (`_`) are replaced with spaces
- Existing ` - ` separators are preserved
- Hyphens (`-`) are replaced with spaces
- Multiple spaces are collapsed to single space

### 8. Final Assembly

Parts are assembled with specific formatting:
1. **Title** (cleaned name)
2. **Season** (if present) - prefixed with ` - `
3. **Date** (if present, with any suffix after date) - prefixed with ` - `
4. **Year** (if present and no date) - wrapped in parentheses `(year)`
5. **Resolution** (if present) - prefixed with `#`

## Title Examples

| Technical Name | Human-Friendly Title |
|----------------|---------------------|
| `Do.Not.Expect.Too.Much.From.the.End.of.the.World.2023.1080p.AMZN.WEB-DL.H.264.mkv` | `Do Not Expect Too Much From the End of the World (2023) #1080p` |
| `Ponies.S01.1080p.PCOK.WEB-DL.H264` | `Ponies - Season 1 #1080p` |
| `Major.Grom.Igra.protiv.pravil.S01.2025.WEB-DL.HEVC.2160p.SDR.ExKinoRay` | `Major Grom Igra protiv pravil - Season 1 (2025) #2160p` |
| `Sting - Live At The Olympia Paris.2017.BDRip1080p` | `Sting - Live At The Olympia Paris (2017) #1080p` |
| `Kak.priruchit.lisu.S01.2025.WEB-DL.HEVC.2160p.SDR.ExKinoRay` | `Kak priruchit lisu - Season 1 (2025) #2160p` |
| `2ChicksSameTime.25.04.14.Bonnie.Rotten.And.Skin.Diamond.2160p.MP4.mp4` | `2ChicksSameTime - 25.04.14 - Bonnie Rotten And Skin Diamond #2160p` |
| `The.Matrix.1999.1080p.BluRay.x264` | `The Matrix (1999) #1080p` |
| `Documentary.4K.HDR.2023` | `Documentary (2023) #2160p` |

## Play Buttons (macOS)

Media torrents display Play buttons below the status line for quick access to downloaded files.

### Features

- **Single file torrents:** Show `▶ Play` button
- **Multi-file torrents:** Show buttons for each downloaded media file
- **Episode detection:** Files with `S01E05` or `1x05` patterns show as `▶ E1`, `▶ E2`, etc.
- **Season grouping:** Multiple seasons show headers (`Season 1:`, `Season 2:`) followed by episode buttons
- **Single season:** No header shown, just episode buttons (`▶ E1`, `▶ E2`, ...)
- **Non-episode files:** Show humanized filename without resolution tags (e.g., `▶ Artist - Track Name`)
- **CUE file support:** If a `.cue` file exists alongside an audio file, the `.cue` is opened instead
- **Up to 100 files:** Maximum of 100 play buttons per torrent

### Individual File Title Rules

Button titles for individual files follow these rules:

1. **Episode files** (`S01E05`, `1x05` patterns): Show as `▶ E5`, `▶ E12`, etc.
2. **Non-episode files**: Show humanized filename with technical tags AND resolution stripped
   - Resolution suffixes (`#2160p`, `#1080p`, etc.) are removed from button titles
   - All technical tags (codecs, sources, etc.) are removed
   - Example: `Artist.Track.2160p.FLAC.flac` → `▶ Artist Track`

### Supported Media Extensions

**Video:** mkv, avi, mp4, mov, wmv, flv, webm, m4v, mpg, mpeg, ts, m2ts, vob, 3gp, ogv

**Audio:** mp3, flac, wav, aac, ogg, wma, m4a, ape, alac, aiff, opus, cue

### Episode Name Humanization

Filenames are converted to readable episode names:

| Filename Pattern | Button Title |
|-----------------|--------------|
| `Show.S01E05.720p.mkv` | `▶ E5` |
| `Show.S1.E12.HDTV.mp4` | `▶ E12` |
| `Show.1x05.720p.mkv` | `▶ E5` |
| `Artist.Track.Name.mp3` | `▶ Artist Track Name` |
| `Concert.2160p.FLAC.flac` | `▶ Concert` |

## Implementation

The transformation is implemented in:

- **macOS:** `NSStringAdditions.mm` - `humanReadableTitle` and `humanReadableEpisodeName` properties on `NSString`
- **macOS:** `Torrent.mm` - `playableFiles` property for media file detection
- **macOS:** `TorrentTableView.mm` - Play button UI and dynamic row height
- **Web UI:** `formatter.js` - `Formatter.humanTitle()` function

The original technical name remains available via the `name` property and is shown in the Inspector (detail view) where the exact filename may be needed.
