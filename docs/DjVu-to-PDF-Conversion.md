## DjVu to PDF conversion (macOS)

Transmission’s macOS client can create a companion `.pdf` for completed `.djvu` / `.djv` files. The implementation lives in `macosx/DjvuConverter.mm`.

### Goals

- **Correctness**: PDF page size matches the DjVu’s page size (uses DjVu pixel size + DPI).
- **Responsiveness**: conversions run off the UI thread and are throttled.
- **Deterministic encoding**: PDF uses explicit image filters (JBIG2Decode + JPXDecode), not “draw pixels and let CoreGraphics choose”.

### Backend (always-on, deterministic)

The converter writes an image-only PDF directly (PDF objects + xref), using:

- **DjVuLibre** (`ddjvuapi`) to decode and render.
- **JBIG2** via **jbig2enc + Leptonica** for 1‑bit masks (`/JBIG2Decode` + `/JBIG2Globals`).
- **JPEG 2000** via **Grok** for grayscale/color backgrounds (`/JPXDecode`, JP2 stream).

### Content detection and encoding

Each page is encoded as a **single image XObject**, chosen by content:

- **Bitonal pages** → **JBIG2** (1‑bit) using DjVu’s mask rendering.
- **Grayscale pages** → **JP2 grayscale** (Grok).
- **Color pages** → **JP2 RGB** (Grok).

Bitonal detection is based on the rendered grayscale content, not `ddjvu_page_get_type()`.

### Pipeline overview

1. **Scan completed files** (entry point: `+[DjvuConverter checkAndConvertCompletedFiles:]`)
   - Runs frequently during UI updates, so it’s **throttled per torrent** (5 seconds).
   - Builds a set of PDF base names already inside the torrent; if a matching PDF exists, the DjVu is skipped.
   - For each `.djvu` / `.djv` file:
     - Require **100% completion**.
     - Skip if a companion PDF already exists on disk.
     - Skip if already queued for this torrent (tracked by `sConversionQueue`).
   - Enqueue conversions on `sConversionDispatchQueue` (**serial**, QoS **utility**).

2. **Convert one DjVu to PDF** (entry point: `+[DjvuConverter convertDjvuFile:toPdf:]`)
   - Creates a DjVuLibre context and document (`ddjvu_context_t`, `ddjvu_document_t`), waits for decode to finish, and bails on errors.
   - Renders pages at bounded DPI:
     - **Max DPI**: no higher than `pageDpi`
     - Clamp so neither render dimension exceeds **4000 px**.
   - Detects content and crops to the minimal bounding rectangle (threshold **245**):
     - **Grayscale** pages: threshold on the grayscale buffer.
     - **Color** pages: threshold on RGB content.
     - **Bitonal** pages: uses DjVu’s mask rendering and clips to foreground.
   - Encodes deterministically:
     - **JBIG2** via jbig2enc for bitonal pages (multipage globals + per-page segments, refinement enabled).
     - **JP2** via Grok for grayscale/color pages.
   - Writes to a temp file, then atomically renames to the final path on success.

3. **Write the PDF** (`writePdfDeterministic`)
   - Writes PDF objects and XRef manually to avoid non-deterministic encoders.
   - Each page is a single image XObject + a tiny content stream to place it.
   - JBIG2 pages reference `/JBIG2Globals` objects for better compression.

4. **Update UI caches and status**
   - Conversion status uses per-torrent tracking:
     - `sActiveConversions`, `sPendingConversions`, `sFailedConversions`.
   - Per-file page progress is tracked so the status string can report `"X of Y pages"`.
   - On completion, a `DjvuConversionComplete` notification invalidates cached playable files and triggers a UI refresh in `Torrent.mm`.

### PDF page sizing

PDF page size is computed from the DjVu’s pixel dimensions and DPI:

- `pdfWidthPoints  = pageWidthPx  * 72 / pageDpi`
- `pdfHeightPoints = pageHeightPx * 72 / pageDpi`

The image XObject is placed at the computed crop rectangle in PDF space, so the effective raster DPI matches the chosen target DPI (unless reduced by the 4000px clamp).

### Document outline (Contents)

If the DjVu file contains an outline (bookmarks), it is copied into the PDF’s `/Outlines` tree.

Outline parsing behavior:

- Reads DjVu outline entries via `miniexp` and keeps only valid entries.
- Resolves targets using:
  - file info names/titles (`ddjvu_document_get_fileinfo`) and
  - `ddjvu_document_search_pageno()` for named targets.
- When the target resolves to a page number, it is converted to a 0‑based index for the PDF.
- Invalid entries are dropped; valid entries keep their child hierarchy.

### Notes

- **Licensing**: Grok is AGPL. Ensure this is acceptable for your distribution.

