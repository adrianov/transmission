# Pieces Bar

Transmission can draw an advanced two-strip progress indicator for every
torrent in its main window. The top strip is the **pieces bar**: one
column per torrent piece, colored by how much of that piece has been
downloaded. The bottom strip is the regular percent-done progress bar.

## Per-client behavior

### GTK client

- The feature is controlled by the boolean preference `show-pieces-bar`
  (quark `TR_KEY_show_pieces_bar`). Its default value is `true`, so the
  pieces bar is visible on the first run.
- Toggle at runtime via **View → Show Pieces Bar**. The setting is
  persisted to `settings.json` in the normal way.
- Rendering is done in `gtk/PiecesProgressBar.cc`. The widget is used by
  both the GTK3 cell-renderer path (`gtk/TorrentCellRenderer.cc`) and
  the GTK4 list-item factory (`gtk/ui/gtk4/TorrentListItem*.ui`), so the
  look is identical regardless of the GTK version.

### macOS client

- Controlled by the `PiecesBar` boolean in `NSUserDefaults` (toggled
  from **View → Show Pieces Bar**).
- Rendering implemented in `macosx/ProgressBarView.mm`; the GTK widget
  is a deliberate port of the same algorithm.

## Visualization rules

The algorithm is shared between GTK and macOS:

- Each piece column is blended between a background color and blue based
  on the fraction already downloaded (0.0 → background, 1.0 → blue).
- When a piece becomes fully-downloaded, the column is drawn in **orange**
  on the next refresh, then returns to blue on subsequent ticks. This
  produces a brief highlight flash that draws attention to progress.
- If a torrent has no metadata yet (magnet link) the strip is drawn as a
  single neutral fill.
- The pieces strip is capped to 324 columns (18 × 18). Torrents with
  more pieces are bucketed into 324 equal-sized ranges and the fraction
  of each bucket that is complete is displayed.

## See also

- `libtransmission/transmission.h` — `tr_torrentAmountFinished` is the
  underlying API used to populate the per-piece completion values.
- `macosx/ProgressBarView.mm` — canonical reference implementation.
- `gtk/PiecesProgressBar.cc` — GTK port.
