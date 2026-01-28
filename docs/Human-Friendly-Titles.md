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

Any trailing file extension (2 to 5 alphanumeric characters following a dot) is automatically stripped from the title.

### 2. Bracket Metadata Extraction

Square bracket metadata like `[2006, Documentary, DVD5]` is parsed:
- Year is extracted from brackets if present
- Disc format tags (DVD5, BD50, etc.) are extracted from brackets
- Content descriptors (Documentary, etc.) are kept in brackets
- Empty brackets are removed entirely

Example: `Album - [2006, Documentary, DVD5]` → `Album - [Documentary] (2006) #DVD5`

### 3. Resolution/Format Extraction

Resolution and disc format tags are extracted and shown with `#` prefix:

**Video Resolutions:**
- `2160p`, `1080p`, `720p`, `480p` - kept as-is
- `8K` - kept as `#8K`
- `4K`, `UHD` - normalized to `#2160p`

**Disc Formats:**
- `DVD`, `DVD5`, `DVD9` - shown as `#DVD`, `#DVD5`, `#DVD9`
- `BD25`, `BD50`, `BD66`, `BD100` - shown as `#BD25`, `#BD50`, etc.

**Legacy Codecs:**
- `XviD`, `DivX` - shown lowercase as `#xvid`, `#divx`

**Audio Formats:**
- `MP3`, `FLAC`, `OGG`, `AAC`, `WAV`, `APE`, `ALAC`, `WMA`, `OPUS`, `M4A`
- Shown lowercase as `#mp3`, `#flac`, etc.

Merged patterns like `BDRip1080p` are split to `BDRip 1080p` before processing.

### 4. Season/Episode Detection

Season markers are converted to readable format:
- `S01` → `Season 1`
- `S01E05` → `Season 1` (episode number removed from title)
- `S12` → `Season 12`

### 5. Year Extraction

Four-digit years (1900-2099) are extracted and shown in parentheses.

**Year intervals:**
- `2000 - 2003` or `2000-2003` → `(2000-2003)`
- Intervals take precedence over single years

**Handling existing parentheses:**
- If the year is already in parentheses like `Movie (2024) 1080p`, the parentheses are preserved as-is
- Years with preceding dots like `Movie.2024.1080p` have the dot removed
- The year is not duplicated in the output

### 6. Date Detection

Two date formats are supported:
- `DD.MM.YYYY` (e.g., `25.10.2021`) - full date format
- `YY.MM.DD` (e.g., `25.04.14`) - short date format

Dates in parentheses like `(25.10.2021)` are also recognized.
When a full date is detected, the year portion is not extracted separately.

### 7. Technical Tags Removal

The following technical tags are filtered out:

**Video Sources:**
- `WEB-DL`, `WEBDL`, `WEBRip`, `BDRip`, `BluRay`, `HDRip`, `DVDRip`, `HDTV`
- Any `[Source]-?Rip` variants (e.g., `WEB-Rip`, `DLRip`) are removed via regex.
- Any `[Source]HD` variants (e.g., `EniaHD`, `playHD`, `HDCLUB`) are removed via regex.
- Any `[Source]-?SbR` variants (e.g., `SbR`, `-SbR`) are removed via regex.

**Video Codecs:**
- `HEVC`, `H264`, `H.264`, `H265`, `H.265`, `x264`, `x265`, `AVC`, `10bit`

**Audio Codecs:**
- `AAC`, `AC3`, `DTS`, `Atmos`, `TrueHD`, `FLAC`, `EAC3`

**HDR Formats:**
- `SDR`, `HDR`, `HDR10`, `DV`, `DoVi`

**Streaming Sources:**
- `AMZN`, `NF`, `DSNP`, `HMAX`, `PCOK`, `ATVP`, `APTV`, `EniaHD`, `HDCLUB`

**Release Info:**
- `ExKinoRay`, `RuTracker`, `LostFilm`, `MP4`, `IMAX`, `REPACK`, `PROPER`, `EXTENDED`, `UNRATED`, `REMUX`, `HDCLUB`, `Jaskier`, `MVO`

**VR/3D Format Tags:**
- `180`, `360`, `180x180`, `3dh`, `3dv`, `LR`, `TB`, `SBS`, `OU`
- `MKX200`, `FISHEYE190`, `RF52`, `VRCA220`

### 8. Separator Normalization

**Dot handling:**
- Dots are replaced with spaces only if the title has no spaces (dot-separated names like `Movie.Name.2020`)
- If the title already contains spaces, dots are preserved (e.g., `Vol. 1`, `Dr. Strange`)
- Dots preceding removed tags are also removed to avoid artifacts
- Ellipsis (`...`) is always preserved

**Cleanup rules:**
- `Paris. .Bonus` → `Paris. Bonus` (dot-space-dot cleaned)
- `Paris .Bonus` → `Paris Bonus` (orphan dot removed)
- Underscores (`_`) are replaced with spaces
- Existing ` - ` separators are preserved
- Hyphens (`-`) between letters (hyphenated words like `Butt-Head`, `Full-Moon`) are preserved; do not add spaces around them
- Other hyphens (with space on at least one side) are normalized to ` - `
- Multiple spaces are collapsed to single space

### 9. Final Assembly

Parts are assembled with specific formatting:
1. **Title** (cleaned name)
2. **Season** (if present) - prefixed with ` - `
3. **Year** (if present and no date) - wrapped in parentheses `(year)`
4. **Date** (if present) - wrapped in parentheses `(date)`
5. **Resolution/Format** (if present) - prefixed with `#`

## Title Examples

| Technical Name | Human-Friendly Title |
|----------------|---------------------|
| `Do.Not.Expect.Too.Much.From.the.End.of.the.World.2023.1080p.AMZN.WEB-DL.H.264.mkv` | `Do Not Expect Too Much From the End of the World (2023) #1080p` |
| `Ponies.S01.1080p.PCOK.WEB-DL.H264` | `Ponies - Season 1 #1080p` |
| `Major.Grom.Igra.protiv.pravil.S01.2025.WEB-DL.HEVC.2160p.SDR.ExKinoRay` | `Major Grom Igra protiv pravil - Season 1 (2025) #2160p` |
| `Sting - Live At The Olympia Paris.2017.BDRip1080p` | `Sting - Live At The Olympia Paris (2017) #1080p` |
| `Les Petits Chanteurs - Vol. 1 - [2006, Documentary, DVD5]` | `Les Petits Chanteurs - Vol. 1 - [Documentary] (2006) #DVD5` |
| `Sting - ...Nothing Like The Sun - 2025 [Japan]` | `Sting - ...Nothing Like The Sun - [Japan] (2025)` |
| `Adriana Chechik Compilation! (25.10.2021)_1080p.mp4` | `Adriana Chechik Compilation! (25.10.2021) #1080p` |
| `VRCosplayX_Severance_Helly_A_XXX_Parody_8K_180_180x180_3dh.mp4` | `VRCosplayX Severance Helly A XXX Parody #8K` |
| `Some.Movie.2020.DVD9.mkv` | `Some Movie (2020) #DVD9` |
| `Concert.BD50.2019` | `Concert (2019) #BD50` |
| `The.Matrix.1999.1080p.BluRay.x264` | `The Matrix (1999) #1080p` |
| `Documentary.4K.HDR.2023` | `Documentary (2023) #2160p` |
| `Kinds of Kindness (2024) WEB-DL SDR 2160p.mkv` | `Kinds of Kindness (2024) #2160p` |
| `Movie.Name.2004.XviD.avi` | `Movie Name (2004) #xvid` |
| `Golden Disco Hits - 2000 - 2003` | `Golden Disco Hits (2000-2003)` |
| `Artist - Album Name (2020) [FLAC]` | `Artist - Album Name (2020) #flac` |
| `Artist.Album.2019.MP3` | `Artist Album (2019) #mp3` |
| `The.White.Lotus.S03E05.Full-Moon.Party.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv` | Episode button: `▶ E5 - Full-Moon Party` |
| `Beavis.and.Butt-Head.Do` | `Beavis and Butt-Head Do` |

## Play Buttons (macOS)

Media torrents display Play buttons below the status line for quick access to downloaded files.

### Features

- **Single file torrents:** Show `▶ Play` button
- **Multi-file torrents:** Show buttons for each media file that has started downloading
- **Progress-based visibility:** Buttons only appear when file progress > 0% (can't play unstarted files)
- **Progress display:** Downloading files show percentage (e.g., `▶ E5 (45%)`), completed files show no percentage
- **Documents:** PDF/EPUB files show Read buttons with a book icon, opened in Books
- **Books in folders:** PDF/EPUB/DJV/DJVU collections show `N books` subtitle and use a book file icon
- **DJVU/DJV:** Read button appears only when a default app is registered; opens in that app
- **Single document:** The button label is `Read`
- **Document readiness:** Read buttons appear only when the file is 100% downloaded
- **Episode detection:** Files with `S01E05` or `1x05` patterns show as `▶ E1`, `▶ E2`, etc.
- **Episode title detection:** If a title follows the episode marker, it is extracted and cleaned (e.g., `▶ E1 - The Beginning`, `▶ E5 - Full-Moon Party`)
- **Technical tag removal:** Titles are aggressively cleaned of technical tags like `1080p`, `WEB-DL`, `H264`, `AMZN`, `EniaHD`, etc. before title extraction
- **Hyphen preservation:** Hyphens in hyphenated words (e.g., `Full-Moon`) are preserved and not converted to spaces
- **Dot-to-space conversion:** Dots between words in episode titles are converted to spaces (e.g., `Full-Moon.Party` → `Full-Moon Party`)
- **Redundancy removal:** If the detected episode title is just a repeat of the series name, it is simplified to just the episode number
- **Common lexeme removal:** If all episodes in a torrent share the same tag at the same position (start or end of the title), that tag is automatically removed as garbage.
- **Season grouping:** Multiple seasons show headers (`Season 1:`, `Season 2:`) followed by episode buttons
- **Single season:** No header shown, just episode buttons (`▶ E1`, `▶ E2`, ...)
- **Non-episode files:** Show lightly humanized filename (separator cleanup) (e.g., `▶ Artist Track Name`)
- **CUE file support:** If a `.cue` file exists alongside an audio file, the `.cue` is opened instead
- **Tooltip paths:** Play button tooltips always show the full, uncut absolute file path, with symlinks resolved to canonical paths
- **DVD/Blu-ray support:** Torrents with `VIDEO_TS` or `BDMV` folders are detected as disc media
- **Multi-disc torrents:** Torrents with multiple discs (e.g., `Disk.1/VIDEO_TS`, `Disk.2/VIDEO_TS`) show individual play buttons for each disc
- **Up to 100 files:** Maximum of 100 play buttons per torrent

### Individual File Title Rules

Button titles for individual files follow these rules:

1. **Episode files** (`S01E05`, `1x05` patterns): Show as `▶ E5`, `▶ E12`, etc.
   - If a title is detected after the marker, it shows as `▶ E5 - Title`.
   - Technical tags (`1080p`, `HEVC`, etc.) and redundant series names are stripped.
2. **Non-episode files**: Show filename with lightweight separator normalization
   - If the name is separator-heavy (lots of `.` / `-` / `_` and few/no spaces), separators are replaced with spaces
   - Numeric separators inside dates/ranges are preserved (e.g., `25.04.14`, `2000-2003`)
   - Years/dates/resolution/technical tags are not extracted (that logic is reserved for torrent title humanization)
3. **Readable titles shortcut:** If a name already has spaces (or is not separator-heavy), it is used as-is (no extra parsing).

### DVD/Blu-ray Disc Support

Torrents containing DVD or Blu-ray disc structures receive special handling:

**Detection:**
- **DVD:** Detected by presence of `VIDEO_TS.IFO` file (not just `VIDEO_TS` folder name)
- **Blu-ray:** Detected by presence of `index.bdmv` file within a `BDMV` folder

**Multi-disc torrents:**
- Torrents may contain multiple discs in separate folders (e.g., `Disk.1/VIDEO_TS/`, `Disk.2/VIDEO_TS/`)
- Each disc gets its own play button showing the folder name (e.g., `▶ Disk.1`, `▶ Disk.2`)
- Single-disc torrents show `▶ DVD` or `▶ Blu-ray`
- The subtitle shows "X discs" instead of video count

**Playback:**
- VLC is preferred for disc playback, launched with `dvd://` or `bluray://` protocol
- IINA is used as fallback if VLC is not installed
- The disc root folder (parent of `VIDEO_TS` or `BDMV`) is passed to the player
- IINA is preferred for album playback (including cue+flac albums), with system default music player as fallback

**Progress display:**
- VOB files (DVD) and M2TS files (Blu-ray) are not counted as separate videos
- Progress is calculated per-disc based on consecutive download progress
- Play buttons only appear when progress > 0% (after downloading starts)
- Buttons show percentage while downloading (e.g., `▶ Disk.1 (45%)`), no percentage when complete

**Download priority:**
- Disc index files are prioritized for download before video content
- See [Piece-Download-Priority.md](Piece-Download-Priority.md) for details

### Supported Media Extensions

**Video:** mkv, avi, mp4, mov, wmv, flv, webm, m4v, mpg, mpeg, ts, m2ts, vob, 3gp, ogv

**Audio:** mp3, flac, wav, aac, ogg, wma, m4a, ape, alac, aiff, opus, cue

**Documents:** pdf, epub, djv, djvu

### Episode Name Humanization

Filenames are converted to readable episode names:

| Filename Pattern | Button Title |
|-----------------|--------------|
| `Show.S01E05.720p.mkv` | `▶ E5` |
| `Show.S1.E12.HDTV.mp4` | `▶ E12` |
| `Show.1x05.720p.mkv` | `▶ E5` |
| `Show.S03E05.Full-Moon.Party.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv` | `▶ E5 - Full-Moon Party` |
| `Artist.Track.Name.mp3` | `▶ Artist Track Name` |
| `Concert.2160p.FLAC.flac` | `▶ Concert 2160p FLAC` |

**Episode Title Extraction Rules:**
- Episode titles are extracted from text following the episode marker (e.g., `S03E05` or `E05`)
- Dots (`.`) between words are converted to spaces (e.g., `Full-Moon.Party` → `Full-Moon Party`)
- Hyphens in hyphenated words are preserved (e.g., `Full-Moon` stays as `Full-Moon`, not `Full Moon`)
- Technical tags (resolutions, codecs, release info) are stripped before title processing
- Only known video file extensions (`.mkv`, `.mp4`, `.avi`, etc.) are removed; words that look like extensions (e.g., `.Party`) are preserved
- If the extracted title is just a repeat of the series name, it's simplified to just the episode number

## Implementation

The transformation is implemented in:

- **macOS:** `NSStringAdditions.mm` - `humanReadableTitle`, `humanReadableFileName`, and `humanReadableEpisodeName` properties on `NSString`
- **macOS:** `Torrent.mm` - `playableFiles` property for media file detection
- **macOS:** `TorrentTableView.mm` - Play button UI and dynamic row height
- **Web UI:** `formatter.js` - `Formatter.humanTitle()` (torrent list) and `Formatter.humanFileName()` (file list)

The original technical name remains available via the `name` property and is shown in the Inspector (detail view) where the exact filename may be needed.
