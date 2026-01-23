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

### Layer mapping

DjVu page type from `ddjvu_page_get_type()` guides what gets embedded:

- **PHOTO** → background only (JP2)
- **BITONAL** → mask only (JBIG2)
  - If a “bitonal” page is detected to contain non‑bitonal grayscale/color, it is treated as PHOTO to avoid blank output.
- **COMPOUND** → background (JP2) + mask (JBIG2)

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
   - Renders page layers at bounded DPI:
     - **Background**: up to **200 DPI** (never above `pageDpi`)
     - **Mask**: up to **300 DPI** (never above `pageDpi`)
     - Clamp so neither render dimension exceeds **4000 px**.
   - Encodes layers deterministically:
     - **Background** → **JP2** via Grok
     - **Mask** → **JBIG2** via jbig2enc (multipage: globals + per-page segments)
   - Writes to a temp file, then atomically renames to the final path on success.

### PDF page sizing

PDF page size is computed from the DjVu’s pixel dimensions and DPI:

- `pdfWidthPoints  = pageWidthPx  * 72 / pageDpi`
- `pdfHeightPoints = pageHeightPx * 72 / pageDpi`

The background and mask XObjects are drawn to fill the full page rectangle, so the effective raster DPI is approximately the chosen target DPI (unless reduced by the 4000px clamp).

### Notes

- **Licensing**: Grok is AGPL. Ensure this is acceptable for your distribution.

