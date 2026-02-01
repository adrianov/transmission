## DjVu to PDF conversion (macOS)

Transmission’s macOS client can create a companion `.pdf` for completed `.djvu` / `.djv` files. The implementation lives in `macosx/DjvuConverter.mm`.

### Goals

- **Correctness**: PDF page size matches the DjVu’s page size (uses DjVu pixel size + DPI).
- **Responsiveness**: conversions run off the UI thread and are throttled.
- **Deterministic encoding**: PDF uses explicit image filters (/JBIG2Decode + /DCTDecode), not “draw pixels and let CoreGraphics choose”.

### Backend (always-on, deterministic)

The converter writes an image-only PDF directly (PDF objects + xref), using:

- **DjVuLibre** (`ddjvuapi`) to decode and render.
- **JBIG2** via **jbig2enc + Leptonica** for 1‑bit masks (`/JBIG2Decode` + `/JBIG2Globals`).
- **JPEG** via **libjpeg-turbo** for grayscale/color backgrounds (`/DCTDecode`).

### Content detection and encoding

Each page is encoded as a **single image XObject**, chosen by content:

- **Bitonal pages** → **JBIG2** (1‑bit) using DjVu’s mask rendering.
- **Grayscale pages** → **JPEG** (libjpeg-turbo).
- **Color pages** → **JPEG RGB** (libjpeg-turbo).

Bitonal detection uses `ddjvu_page_get_type()` when available: PHOTO pages are never treated as bitonal; BITONAL pages are treated as bitonal; otherwise it is based on the rendered grayscale content.

**Compound pages** (photo/background + text): the converter merges into a **single JBIG2** only when **separately** just the background layer or just the full-page composite (photo) is considered bitonal. In that case it binarizes the background at render size, ORs with the text mask, crops, and encodes as one JBIG2. Otherwise the page is encoded as background JPEG + foreground JBIG2 (two layers). The background layer is rendered at up to 150 DPI (`MaxBgDpi`).

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
     - **Max DPI**: no higher than 300 or page DPI, whichever is lower (`MaxRenderDpi`).
     - Clamp so neither render dimension exceeds **4000 px**.
   - Detects content and crops to the minimal bounding rectangle using **Otsu adaptive threshold** (Leptonica) on grayscale; bitonal pages use DjVu’s mask rendering and clip to foreground.
   - Encodes deterministically:
     - **JBIG2** via jbig2enc for bitonal pages (shared globals + per-page segments).
     - **JPEG** via libjpeg-turbo for grayscale/color pages.
   - Builds the PDF in memory, then writes once to the final path with a single `fwrite` (no temp file; no leftover `.tmp` on shutdown).

3. **Write the PDF** (`IncrementalPdfWriter`)
   - Writes PDF objects and XRef to a memory buffer, then flushes to disk in one atomic write.
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

- Grayscale/color encoding uses JPEG (libjpeg-turbo).

