# Media Categories (macOS)

The macOS client auto-assigns torrents to groups (Video, Audio, Books, Adult) using detected media category.

## Categories

- **video** — video extensions (mkv, mp4, avi, etc.) or folder with dominant video files
- **audio** — audio extensions (mp3, flac, etc.) or folder with dominant audio
- **books** — book extensions (pdf, epub, djvu, etc.) or folder with dominant books
- **adult** — video content detected as adult by heuristic (see below)

Only video can be classified as adult; audio/books are never mapped to adult.

## Adult heuristic

A torrent is treated as **adult** if any of the following is true:

1. **Tracker domain** — Any tracker announce URL has host `pornolab.net`, or the torrent **Comment** field contains `pornolab.net`. (Tracker domain is often stored in Comment rather than in the trackers list.)
2. **Video + keywords** — Base category is video and the torrent name or Comment contains adult keywords/tags (e.g. `[18+]`, `[adult]`, `nsfw`, `porn`, `xxx`, `onlyfans`, `pornhub`, `xvideos`).

File-level category (`mediaCategoryForFile:`): a file is adult if its extension is video and either the torrent is adult (above) or the file path contains adult keywords.

## API

- **Torrent** (macosx): `detectedMediaCategory` (torrent-level), `mediaCategoryForFile:` (per file), `isAdultTorrent`
- **GroupsController**: `groupIndexForMediaCategory:` maps category string to group; `ensureMediaGroupsExist` creates Video, Audio, Books, Adult groups if missing.
