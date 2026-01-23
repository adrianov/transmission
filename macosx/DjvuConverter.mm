// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "DjvuConverter.h"
#import "Torrent.h"
#import "FileListNode.h"

#import <ddjvuapi.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>

// macOS defines `fract1` / `fract2` macros via CarbonCore's FixMath.h, which
// collide with Leptonica's function parameter names.
#ifdef fract1
#undef fract1
#endif
#ifdef fract2
#undef fract2
#endif

#include <leptonica/allheaders.h>
#include <jbig2enc.h>
#include <grok.h>

// Track files that have been queued for conversion (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sConversionQueue = nil;
static NSMutableDictionary<NSString*, NSNumber*>* sLastScanTime = nil;
static dispatch_queue_t sConversionDispatchQueue = nil;

// Forward declarations for per-file page tracking helpers (used by conversion backends)
static void setTotalPagesForPath(NSString* djvuPath, int total);
static void incrementDonePagesForPath(NSString* djvuPath);
static void clearPageTrackingForPath(NSString* djvuPath);

static void computeRenderDimensions(int pageWidth, int pageHeight, int pageDpi, int targetDpi, int* outWidth, int* outHeight)
{
    int renderWidth = (int)((double)pageWidth * targetDpi / pageDpi);
    int renderHeight = (int)((double)pageHeight * targetDpi / pageDpi);

    // Clamp to max 4000 pixels
    if (renderWidth > 4000 || renderHeight > 4000)
    {
        double scale = 4000.0 / MAX(renderWidth, renderHeight);
        renderWidth = (int)(renderWidth * scale);
        renderHeight = (int)(renderHeight * scale);
    }

    *outWidth = renderWidth;
    *outHeight = renderHeight;
}

static void ensureGrokInitialized()
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Must be called before using Grok APIs. Use Grok's default thread count (0 = all).
        grk_initialize(nullptr, 0, nullptr);
    });
}

struct DjvuPdfBackground
{
    bool gray = false;
    int w = 0;
    int h = 0;
    std::vector<uint8_t> jp2;
};

struct DjvuPdfPageInfo
{
    int pageWidth = 0;
    int pageHeight = 0;
    int pageDpi = 0;
    ddjvu_page_type_t pageType = DDJVU_PAGETYPE_BITONAL;

    double pdfWidth = 0.0;
    double pdfHeight = 0.0;

    bool hasBackground = false;
    DjvuPdfBackground background;

    bool hasMask = false;
    int maskW = 0;
    int maskH = 0;
};

static bool isGrayscaleRgb24(unsigned char const* rgb, int width, int height, size_t rowBytes)
{
    int stepX = MAX(1, width / 512);
    int stepY = MAX(1, height / 512);

    for (int y = 0; y < height; y += stepY)
    {
        auto const* row = rgb + (size_t)y * rowBytes;
        for (int x = 0; x < width; x += stepX)
        {
            unsigned char r = row[x * 3 + 0];
            unsigned char g = row[x * 3 + 1];
            unsigned char b = row[x * 3 + 2];
            if (abs((int)r - (int)g) > 2 || abs((int)r - (int)b) > 2)
                return false;
        }
    }

    return true;
}

static bool isBitonalGray8(unsigned char const* gray, int width, int height, size_t rowBytes)
{
    // Heuristic: treat as bitonal when the non-white pixels are mostly near-black.
    unsigned char constexpr WhiteMaxBlackness = 16; // >= 239 treated as white-ish
    unsigned char constexpr LowBlackness = 32;
    unsigned char constexpr HighBlackness = 128;
    double constexpr MinRatio = 0.75;
    double constexpr MaxTileDarkFraction = 0.80;
    int constexpr TileCount = 16;

    size_t tileSamples[TileCount * TileCount] = {};
    size_t tileLow[TileCount * TileCount] = {};

    size_t nonWhite = 0;
    size_t low = 0;
    size_t high = 0;

    int stepX = MAX(1, width / 512);
    int stepY = MAX(1, height / 512);

    for (int y = 0; y < height; y += stepY)
    {
        auto const* row = gray + (size_t)y * rowBytes;
        int const ty = (y * TileCount) / height;
        for (int x = 0; x < width; x += stepX)
        {
            int const tx = (x * TileCount) / width;
            size_t const tileIdx = (size_t)ty * (size_t)TileCount + (size_t)tx;
            ++tileSamples[tileIdx];

            unsigned char const v = row[x];
            unsigned char const blackness = (unsigned char)(255U - (unsigned)v);

            if (blackness <= WhiteMaxBlackness)
                continue;

            ++nonWhite;

            if (blackness >= LowBlackness)
            {
                ++low;
                ++tileLow[tileIdx];
                if (blackness >= HighBlackness)
                    ++high;
            }
        }
    }

    if (nonWhite == 0)
        return true;

    if (low == 0)
        return false;

    // Reject "photo-like" pages with localized dense dark regions:
    // a small dark picture can satisfy the global ratio, but would get destroyed by 1-bit thresholding.
    double maxTile = 0.0;
    for (size_t i = 0; i < (size_t)TileCount * (size_t)TileCount; ++i)
    {
        if (tileSamples[i] < 64)
            continue;
        maxTile = MAX(maxTile, (double)tileLow[i] / (double)tileSamples[i]);
    }
    if (maxTile > MaxTileDarkFraction)
        return false;

    return (double)high / (double)low >= MinRatio;
}

static NSData* pbmP4DataFromBits(int w, int h, size_t rowBytes, unsigned char const* bits)
{
    NSMutableData* data = [NSMutableData data];
    NSString* header = [NSString stringWithFormat:@"P4\n%d %d\n", w, h];
    [data appendData:[header dataUsingEncoding:NSASCIIStringEncoding]];
    [data appendBytes:bits length:rowBytes * (size_t)h];
    return data;
}

static NSData* renderDjvuMaskPbmData(ddjvu_page_t* page, ddjvu_format_t* grey8, ddjvu_format_t* msb, int renderWidth, int renderHeight, bool preferBitonal, double* outCoverage)
{
    if (outCoverage != nullptr)
        *outCoverage = 0.0;

    ddjvu_rect_t rect = { 0, 0, (unsigned int)renderWidth, (unsigned int)renderHeight };

    // Prefer direct 1-bit output when possible; otherwise render GREY8 and threshold.
    if (preferBitonal)
    {
        size_t rowBytes = ((size_t)renderWidth + 7U) / 8U;
        size_t size = rowBytes * (size_t)renderHeight;
        auto* bits = (unsigned char*)calloc(size, 1);
        if (bits == nullptr)
            return nil;

        int const ok = ddjvu_page_render(page, DDJVU_RENDER_MASKONLY, &rect, &rect, msb, (unsigned long)rowBytes, (char*)bits);
        if (ok && outCoverage != nullptr)
        {
            size_t const fullBytes = (size_t)renderWidth / 8U;
            int const remBits = renderWidth % 8;
            unsigned char const lastMask = remBits != 0 ? (unsigned char)(0xFFU << (8 - remBits)) : 0xFFU;

            size_t ones = 0;
            for (int y = 0; y < renderHeight; ++y)
            {
                auto const* row = bits + (size_t)y * rowBytes;
                for (size_t i = 0; i < fullBytes; ++i)
                    ones += (size_t)__builtin_popcount((unsigned)row[i]);
                if (remBits != 0)
                    ones += (size_t)__builtin_popcount((unsigned)(row[fullBytes] & lastMask));
            }

            *outCoverage = (double)ones / (double)((size_t)renderWidth * (size_t)renderHeight);
        }

        NSData* pbm = ok ? pbmP4DataFromBits(renderWidth, renderHeight, rowBytes, bits) : nil;
        free(bits);
        return pbm;
    }

    size_t grayRowBytes = (size_t)renderWidth;
    size_t graySize = grayRowBytes * (size_t)renderHeight;
    auto* gray = (unsigned char*)malloc(graySize);
    if (gray == nullptr)
        return nil;
    memset(gray, 0xFF, graySize);

    int const ok = ddjvu_page_render(page, DDJVU_RENDER_MASKONLY, &rect, &rect, grey8, (unsigned long)grayRowBytes, (char*)gray);
    if (!ok)
    {
        free(gray);
        return nil;
    }

    size_t bitRowBytes = ((size_t)renderWidth + 7U) / 8U;
    size_t bitSize = bitRowBytes * (size_t)renderHeight;
    auto* bits = (unsigned char*)calloc(bitSize, 1);
    if (bits == nullptr)
    {
        free(gray);
        return nil;
    }

    // Mask-only render in GREY8 uses white background with black text. Threshold to 1-bit.
    unsigned char constexpr Threshold = 127;
    size_t ones = 0;
    for (int y = 0; y < renderHeight; ++y)
    {
        auto const* src = gray + (size_t)y * grayRowBytes;
        auto* dst = bits + (size_t)y * bitRowBytes;
        for (int x = 0; x < renderWidth; ++x)
        {
            if (src[x] < Threshold)
            {
                dst[x / 8] |= (unsigned char)(0x80U >> (x % 8));
                ++ones;
            }
        }
    }

    if (outCoverage != nullptr)
        *outCoverage = (double)ones / (double)((size_t)renderWidth * (size_t)renderHeight);

    NSData* pbm = pbmP4DataFromBits(renderWidth, renderHeight, bitRowBytes, bits);
    free(bits);
    free(gray);
    return pbm;
}

static bool encodeJp2Grok(std::vector<uint8_t>* out, unsigned char const* pixels, int w, int h, size_t stride, bool gray)
{
    if (out == nullptr || pixels == nullptr || w <= 0 || h <= 0 || stride == 0)
        return false;

    ensureGrokInitialized();

    uint16_t const numComps = gray ? 1U : 3U;
    GRK_COLOR_SPACE const colorSpace = gray ? GRK_CLRSPC_GRAY : GRK_CLRSPC_SRGB;

    auto comps = std::make_unique<grk_image_comp[]>(numComps);
    for (uint16_t i = 0; i < numComps; ++i)
    {
        comps[i] = {};
        comps[i].w = (uint32_t)w;
        comps[i].h = (uint32_t)h;
        comps[i].prec = 8;
        comps[i].dx = 1;
        comps[i].dy = 1;
    }

    grk_image* image = grk_image_new(numComps, comps.get(), colorSpace, true);
    if (image == nullptr)
        return false;

    // Copy pixels into Grok's planar int32 component buffers.
    if (gray)
    {
        auto* dst = (int32_t*)image->comps[0].data;
        uint32_t const dstStride = image->comps[0].stride;
        for (int y = 0; y < h; ++y)
        {
            auto const* srcRow = pixels + (size_t)y * stride;
            auto* dstRow = dst + (uint32_t)y * dstStride;
            for (int x = 0; x < w; ++x)
                dstRow[x] = srcRow[x];
        }
    }
    else
    {
        auto* dstR = (int32_t*)image->comps[0].data;
        auto* dstG = (int32_t*)image->comps[1].data;
        auto* dstB = (int32_t*)image->comps[2].data;
        uint32_t const strideR = image->comps[0].stride;
        uint32_t const strideG = image->comps[1].stride;
        uint32_t const strideB = image->comps[2].stride;
        for (int y = 0; y < h; ++y)
        {
            auto const* srcRow = pixels + (size_t)y * stride;
            auto* rRow = dstR + (uint32_t)y * strideR;
            auto* gRow = dstG + (uint32_t)y * strideG;
            auto* bRow = dstB + (uint32_t)y * strideB;
            for (int x = 0; x < w; ++x)
            {
                rRow[x] = srcRow[x * 3 + 0];
                gRow[x] = srcRow[x * 3 + 1];
                bRow[x] = srcRow[x * 3 + 2];
            }
        }
    }

    bool ok = false;
    grk_object* codec = nullptr;
    grk_stream_params stream = {};

    grk_cparameters params;
    grk_compress_set_default_params(&params);
    params.cod_format = GRK_FMT_JP2;
    params.verbose = false;
    params.irreversible = false; // lossless (reversible)

    size_t rawSize = stride * (size_t)h;
    size_t cap = rawSize + 1024U * 1024U;
    cap = MAX(cap, (size_t)64 * 1024);

    for (int attempt = 0; attempt < 3 && !ok; ++attempt)
    {
        std::vector<uint8_t> buf(cap);
        stream.buf = buf.data();
        stream.buf_len = buf.size();

        codec = grk_compress_init(&stream, &params, image);
        if (codec == nullptr)
            break;

        uint64_t const written = grk_compress(codec, nullptr);
        grk_object_unref(codec);
        codec = nullptr;

        if (written != 0 && written <= buf.size())
        {
            out->assign(buf.data(), buf.data() + (size_t)written);
            ok = !out->empty();
            break;
        }

        // Retry with larger output buffer.
        cap *= 2;
    }

    if (codec != nullptr)
        grk_object_unref(codec);
    grk_object_unref(&image->obj);

    return ok;
}

static bool writePdfDeterministic(
    NSString* tmpPdfPath,
    std::vector<DjvuPdfPageInfo> const& pages,
    std::vector<uint8_t> const* jbig2Globals,
    std::vector<std::vector<uint8_t>> const* jbig2Pages)
{
    if (tmpPdfPath == nil || pages.empty())
        return false;

    FILE* fp = fopen(tmpPdfPath.UTF8String, "wb");
    if (fp == nullptr)
        return false;

    auto const closeFile = std::unique_ptr<FILE, int (*)(FILE*)>(fp, fclose);

    // PDF header + binary marker.
    fputs("%PDF-1.7\n%\xE2\xE3\xCF\xD3\n", fp);

    struct PageObjs
    {
        int bg = 0;
        int mask = 0;
        int contents = 0;
        int page = 0;
    };

    std::vector<PageObjs> pageObjs(pages.size());

    int nextObj = 1;
    int const catalogObj = nextObj++;
    int const pagesObj = nextObj++;
    int const jbig2GlobalsObj = (jbig2Globals != nullptr) ? nextObj++ : 0;

    for (size_t i = 0; i < pages.size(); ++i)
    {
        if (pages[i].hasBackground)
            pageObjs[i].bg = nextObj++;
        if (pages[i].hasMask)
            pageObjs[i].mask = nextObj++;
        pageObjs[i].contents = nextObj++;
        pageObjs[i].page = nextObj++;
    }

    int const objCount = nextObj - 1;
    std::vector<uint64_t> offsets((size_t)objCount + 1U, 0);

    auto writeObjBegin = [&](int objNum)
    {
        offsets[(size_t)objNum] = (uint64_t)ftello(fp);
        fprintf(fp, "%d 0 obj\n", objNum);
    };

    auto writeObjEnd = [&]()
    {
        fputs("endobj\n", fp);
    };

    auto writeStreamObj = [&](int objNum, char const* dictPrefix, uint8_t const* bytes, size_t len)
    {
        writeObjBegin(objNum);
        fprintf(fp, "%s/Length %zu >>\nstream\n", dictPrefix, len);
        if (len != 0)
            fwrite(bytes, 1, len, fp);
        fputs("\nendstream\n", fp);
        writeObjEnd();
    };

    // 1) Catalog
    writeObjBegin(catalogObj);
    fprintf(fp, "<< /Type /Catalog /Pages %d 0 R >>\n", pagesObj);
    writeObjEnd();

    // 2) Pages tree
    writeObjBegin(pagesObj);
    fputs("<< /Type /Pages /Kids [", fp);
    for (size_t i = 0; i < pages.size(); ++i)
        fprintf(fp, " %d 0 R", pageObjs[i].page);
    fprintf(fp, " ] /Count %zu >>\n", pages.size());
    writeObjEnd();

    // 3) JBIG2Globals
    if (jbig2GlobalsObj != 0)
    {
        writeStreamObj(jbig2GlobalsObj, "<< ", jbig2Globals->data(), jbig2Globals->size());
    }

    // 4) Per-page objects
    for (size_t i = 0; i < pages.size(); ++i)
    {
        DjvuPdfPageInfo const& p = pages[i];
        PageObjs const& o = pageObjs[i];

        if (p.hasBackground)
        {
            DjvuPdfBackground const& bg = p.background;
            char const* cs = bg.gray ? "/DeviceGray" : "/DeviceRGB";
            writeObjBegin(o.bg);
            fprintf(
                fp,
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8 /Filter /JPXDecode /Length %zu >>\nstream\n",
                bg.w,
                bg.h,
                cs,
                bg.jp2.size());
            fwrite(bg.jp2.data(), 1, bg.jp2.size(), fp);
            fputs("\nendstream\n", fp);
            writeObjEnd();
        }

        if (p.hasMask)
        {
            if (jbig2Pages == nullptr || jbig2GlobalsObj == 0 || i >= jbig2Pages->size())
                return false;

            auto const& maskBytes = (*jbig2Pages)[i];
            writeObjBegin(o.mask);
            fprintf(
                fp,
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /BitsPerComponent 1 /ImageMask true /Filter /JBIG2Decode /DecodeParms << /JBIG2Globals %d 0 R >> /Length %zu >>\nstream\n",
                p.maskW,
                p.maskH,
                jbig2GlobalsObj,
                maskBytes.size());
            fwrite(maskBytes.data(), 1, maskBytes.size(), fp);
            fputs("\nendstream\n", fp);
            writeObjEnd();
        }

        // Contents stream
        std::string contents;
        contents.reserve(128);
        char tmp[256];
        snprintf(tmp, sizeof(tmp), "q\n%g 0 0 %g 0 0 cm\n", p.pdfWidth, p.pdfHeight);
        contents.append(tmp);
        if (p.hasBackground)
            contents.append("/ImBg Do\n");
        if (p.hasMask)
            contents.append("0 g\n/ImM Do\n");
        contents.append("Q\n");

        writeStreamObj(o.contents, "<< ", (uint8_t const*)contents.data(), contents.size());

        // Page dictionary
        writeObjBegin(o.page);
        fprintf(fp, "<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %g %g] ", pagesObj, p.pdfWidth, p.pdfHeight);
        fputs("/Resources << ", fp);
        if (p.hasBackground || p.hasMask)
        {
            fputs("/XObject << ", fp);
            if (p.hasBackground)
                fprintf(fp, "/ImBg %d 0 R ", o.bg);
            if (p.hasMask)
                fprintf(fp, "/ImM %d 0 R ", o.mask);
            fputs(">> ", fp);
        }
        fprintf(fp, ">> /Contents %d 0 R >>\n", o.contents);
        writeObjEnd();
    }

    // XRef + trailer
    uint64_t const xrefOffset = (uint64_t)ftello(fp);
    fprintf(fp, "xref\n0 %d\n", objCount + 1);
    fputs("0000000000 65535 f \n", fp);
    for (int i = 1; i <= objCount; ++i)
        fprintf(fp, "%010llu 00000 n \n", (unsigned long long)offsets[(size_t)i]);

    fprintf(fp, "trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%llu\n%%%%EOF\n", objCount + 1, catalogObj, (unsigned long long)xrefOffset);
    return true;
}

static BOOL convertDjvuFileDeterministic(NSString* djvuPath, NSString* tmpPdfPath)
{
    // Create DJVU context
    ddjvu_context_t* ctx = ddjvu_context_create("Transmission");
    if (!ctx)
        return NO;

    ddjvu_document_t* doc = ddjvu_document_create_by_filename_utf8(ctx, djvuPath.UTF8String, TRUE);
    if (!doc)
    {
        ddjvu_context_release(ctx);
        return NO;
    }

    while (!ddjvu_document_decoding_done(doc))
    {
        ddjvu_message_t* msg = ddjvu_message_wait(ctx);
        if (msg)
            ddjvu_message_pop(ctx);
    }

    if (ddjvu_document_decoding_error(doc))
    {
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    int pageCount = ddjvu_document_get_pagenum(doc);
    if (pageCount <= 0)
    {
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    setTotalPagesForPath(djvuPath, pageCount);

    ddjvu_format_t* rgb24 = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, nullptr);
    ddjvu_format_t* grey8 = ddjvu_format_create(DDJVU_FORMAT_GREY8, 0, nullptr);
    ddjvu_format_t* msb = ddjvu_format_create(DDJVU_FORMAT_MSBTOLSB, 0, nullptr);
    if (!rgb24 || !grey8 || !msb)
    {
        if (rgb24)
            ddjvu_format_release(rgb24);
        if (grey8)
            ddjvu_format_release(grey8);
        if (msb)
            ddjvu_format_release(msb);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    ddjvu_format_set_row_order(rgb24, TRUE);
    ddjvu_format_set_y_direction(rgb24, TRUE);
    ddjvu_format_set_row_order(grey8, TRUE);
    ddjvu_format_set_y_direction(grey8, TRUE);
    ddjvu_format_set_row_order(msb, TRUE);
    ddjvu_format_set_y_direction(msb, TRUE);

    std::vector<DjvuPdfPageInfo> pages((size_t)pageCount);
    DjvuPdfPageInfo* pagesPtr = pages.data();

    dispatch_queue_t encQ = dispatch_queue_create("transmission.djvu.jp2.encode", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t encGroup = dispatch_group_create();

    NSInteger cpu = NSProcessInfo.processInfo.activeProcessorCount;
    NSInteger maxConcurrent = MAX(1, MIN(cpu, 3));
    dispatch_semaphore_t sem = dispatch_semaphore_create(maxConcurrent);

    bool ok = true;
    jbig2ctx* jb = nullptr;

    auto addBlankJbig2Page = [&]() -> bool
    {
        unsigned char zero = 0;
        NSData* pbm = pbmP4DataFromBits(1, 1, 1, &zero);
        PIX* pix = pixReadMemPnm((l_uint8 const*)pbm.bytes, pbm.length);
        if (pix == nullptr)
            return false;
        jbig2_add_page(jb, pix);
        pixDestroy(&pix);
        return true;
    };

    for (int pageNum = 0; pageNum < pageCount && ok; ++pageNum)
    {
        @autoreleasepool
        {
            ddjvu_page_t* page = ddjvu_page_create_by_pageno(doc, pageNum);
            if (!page)
            {
                ok = false;
                break;
            }

            while (!ddjvu_page_decoding_done(page))
            {
                ddjvu_message_t* msg = ddjvu_message_wait(ctx);
                if (msg)
                    ddjvu_message_pop(ctx);
            }

            if (ddjvu_page_decoding_error(page))
            {
                ddjvu_page_release(page);
                ok = false;
                break;
            }

            ddjvu_page_type_t pageType = ddjvu_page_get_type(page);
            int pageWidth = ddjvu_page_get_width(page);
            int pageHeight = ddjvu_page_get_height(page);
            int pageDpi = ddjvu_page_get_resolution(page);
            if (pageWidth <= 0 || pageHeight <= 0 || pageDpi <= 0)
            {
                ddjvu_page_release(page);
                ok = false;
                break;
            }

            DjvuPdfPageInfo& p = pagesPtr[pageNum];
            p.pageWidth = pageWidth;
            p.pageHeight = pageHeight;
            p.pageDpi = pageDpi;
            p.pageType = pageType;
            p.pdfWidth = (double)pageWidth * 72.0 / (double)pageDpi;
            p.pdfHeight = (double)pageHeight * 72.0 / (double)pageDpi;

            int constexpr BgMaxDpi = 200;
            int constexpr MaskMaxDpi = 300;

            int bgDpi = MIN(BgMaxDpi, pageDpi);
            int maskDpi = MIN(MaskMaxDpi, pageDpi);

            bool wantBg = (pageType == DDJVU_PAGETYPE_PHOTO || pageType == DDJVU_PAGETYPE_COMPOUND);
            bool wantMask = (pageType == DDJVU_PAGETYPE_BITONAL || pageType == DDJVU_PAGETYPE_COMPOUND);

            // ddjvu can report UNKNOWN even after decoding is done; don't emit blank pages.
            if (pageType == DDJVU_PAGETYPE_UNKNOWN)
            {
                wantBg = true;
                wantMask = false;
                pageType = DDJVU_PAGETYPE_PHOTO;
                p.pageType = pageType;
            }

            // Some DjVu "compound" pages are effectively just a single image page (no text).
            // If the mask is empty or dense, treat it as a PHOTO page: render full color and skip the mask.
            NSData* compoundMaskPbm = nil;
            int compoundMaskW = 0;
            int compoundMaskH = 0;
            if (pageType == DDJVU_PAGETYPE_COMPOUND)
            {
                computeRenderDimensions(pageWidth, pageHeight, pageDpi, maskDpi, &compoundMaskW, &compoundMaskH);
                bool const preferBitonal = (maskDpi == pageDpi) && (compoundMaskW == pageWidth) && (compoundMaskH == pageHeight);

                double coverage = 0.0;
                compoundMaskPbm = renderDjvuMaskPbmData(page, grey8, msb, compoundMaskW, compoundMaskH, preferBitonal, &coverage);
                if (compoundMaskPbm == nil || compoundMaskPbm.length == 0)
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }

                double constexpr MinTextCoverage = 0.001; // 0.1%
                double constexpr MaxTextCoverage = 0.25; // 25%
                bool const looksLikeTextMask = (coverage >= MinTextCoverage) && (coverage <= MaxTextCoverage);
                if (!looksLikeTextMask)
                {
                    wantMask = false;
                    pageType = DDJVU_PAGETYPE_PHOTO;
                    p.pageType = pageType;
                    compoundMaskPbm = nil;
                }
            }

            // Some DjVu files report BITONAL but actually contain grayscale/color data.
            // If it's not truly bitonal, treat it as a PHOTO page to avoid blank output.
            std::shared_ptr<std::vector<uint8_t>> bitonalProbe;
            int probeW = 0;
            int probeH = 0;
            bool probeIsGray = false;
            std::vector<uint8_t> probeGray;
            if (pageType == DDJVU_PAGETYPE_BITONAL)
            {
                computeRenderDimensions(pageWidth, pageHeight, pageDpi, bgDpi, &probeW, &probeH);
                size_t rowBytes = (size_t)probeW * 3;
                bitonalProbe = std::make_shared<std::vector<uint8_t>>(rowBytes * (size_t)probeH, (uint8_t)0xFF);
                ddjvu_rect_t rect = { 0, 0, (unsigned int)probeW, (unsigned int)probeH };
                int const rendered = ddjvu_page_render(
                    page,
                    DDJVU_RENDER_COLOR,
                    &rect,
                    &rect,
                    rgb24,
                    (unsigned long)rowBytes,
                    (char*)bitonalProbe->data());
                if (rendered)
                {
                    probeIsGray = isGrayscaleRgb24(bitonalProbe->data(), probeW, probeH, rowBytes);
                    if (probeIsGray)
                    {
                        probeGray.resize((size_t)probeW * (size_t)probeH);
                        for (int y = 0; y < probeH; ++y)
                        {
                            auto const* srcRow = bitonalProbe->data() + (size_t)y * rowBytes;
                            auto* dst = probeGray.data() + (size_t)y * (size_t)probeW;
                            for (int x = 0; x < probeW; ++x)
                                dst[x] = srcRow[x * 3 + 0];
                        }
                    }

                    bool const trulyBitonal = probeIsGray && isBitonalGray8(probeGray.data(), probeW, probeH, (size_t)probeW);
                    if (!trulyBitonal)
                    {
                        wantBg = true;
                        wantMask = false;
                        pageType = DDJVU_PAGETYPE_PHOTO;
                        p.pageType = pageType;
                    }
                }
            }

            // Background: always JPEG2000 (JP2)
            if (wantBg)
            {
                int bgW = 0;
                int bgH = 0;
                computeRenderDimensions(pageWidth, pageHeight, pageDpi, bgDpi, &bgW, &bgH);

                size_t rowBytes = (size_t)bgW * 3;
                std::shared_ptr<std::vector<uint8_t>> rgb;

                if (bitonalProbe && bgW == probeW && bgH == probeH)
                {
                    rgb = bitonalProbe;
                }
                else
                {
                    rgb = std::make_shared<std::vector<uint8_t>>(rowBytes * (size_t)bgH, (uint8_t)0xFF);
                    ddjvu_rect_t rect = { 0, 0, (unsigned int)bgW, (unsigned int)bgH };
                    int rendered = ddjvu_page_render(
                        page,
                        pageType == DDJVU_PAGETYPE_COMPOUND ? DDJVU_RENDER_BACKGROUND : DDJVU_RENDER_COLOR,
                        &rect,
                        &rect,
                        rgb24,
                        (unsigned long)rowBytes,
                        (char*)rgb->data());

                    if (!rendered && pageType == DDJVU_PAGETYPE_COMPOUND)
                    {
                        // Some files don't expose background separately; fall back to full render.
                        rendered = ddjvu_page_render(
                            page,
                            DDJVU_RENDER_COLOR,
                            &rect,
                            &rect,
                            rgb24,
                            (unsigned long)rowBytes,
                            (char*)rgb->data());
                    }

                    if (!rendered)
                    {
                        ddjvu_page_release(page);
                        ok = false;
                        break;
                    }
                }

                bool const gray = isGrayscaleRgb24(rgb->data(), bgW, bgH, rowBytes);
                p.hasBackground = true;
                p.background.w = bgW;
                p.background.h = bgH;
                p.background.gray = gray;

                dispatch_group_async(encGroup, encQ, ^{
                    @autoreleasepool
                    {
                        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

                        std::vector<uint8_t> jp2;
                        if (gray)
                        {
                            std::vector<uint8_t> grayBuf;
                            grayBuf.resize((size_t)bgW * (size_t)bgH);
                            for (int y = 0; y < bgH; ++y)
                            {
                                auto const* srcRow = rgb->data() + (size_t)y * rowBytes;
                                auto* dst = grayBuf.data() + (size_t)y * (size_t)bgW;
                                for (int x = 0; x < bgW; ++x)
                                    dst[x] = srcRow[x * 3 + 0];
                            }
                            (void)encodeJp2Grok(&jp2, grayBuf.data(), bgW, bgH, (size_t)bgW, true);
                        }
                        else
                        {
                            (void)encodeJp2Grok(&jp2, rgb->data(), bgW, bgH, rowBytes, false);
                        }

                        if (!jp2.empty())
                            pagesPtr[pageNum].background.jp2 = std::move(jp2);

                        dispatch_semaphore_signal(sem);
                    }
                });
            }

            // Mask: JBIG2 (only for bitonal/compound pages)
            if (wantMask)
            {
                if (jb == nullptr)
                {
                    // Create JBIG2 context on-demand; backfill earlier pages with blanks.
                    jb = jbig2_init(0.85f, 0.5f, 0, 0, false, -1);
                    if (jb == nullptr)
                    {
                        ddjvu_page_release(page);
                        ok = false;
                        break;
                    }

                    for (int i = 0; i < pageNum; ++i)
                    {
                        if (!addBlankJbig2Page())
                        {
                            ddjvu_page_release(page);
                            ok = false;
                            break;
                        }
                    }
                    if (!ok)
                        break;
                }

                int maskW = 0;
                int maskH = 0;
                NSData* pbm = nil;
                if (pageType == DDJVU_PAGETYPE_COMPOUND && compoundMaskPbm != nil)
                {
                    maskW = compoundMaskW;
                    maskH = compoundMaskH;
                    pbm = compoundMaskPbm;
                }
                else
                {
                    computeRenderDimensions(pageWidth, pageHeight, pageDpi, maskDpi, &maskW, &maskH);
                    // Only attempt direct 1-bit when unscaled at source resolution.
                    bool const preferBitonal = (maskDpi == pageDpi) && (maskW == pageWidth) && (maskH == pageHeight);
                    pbm = renderDjvuMaskPbmData(page, grey8, msb, maskW, maskH, preferBitonal, nullptr);
                }

                if (pbm == nil || pbm.length == 0)
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }

                PIX* pix = pixReadMemPnm((l_uint8 const*)pbm.bytes, pbm.length);
                if (pix == nullptr)
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }

                jbig2_add_page(jb, pix);
                pixDestroy(&pix);

                p.hasMask = true;
                p.maskW = maskW;
                p.maskH = maskH;
            }
            else if (jb != nullptr)
            {
                // Keep page index alignment for jbig2enc outputs.
                if (!addBlankJbig2Page())
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }
            }

            ddjvu_page_release(page);

            incrementDonePagesForPath(djvuPath);
        }
    }

    dispatch_group_wait(encGroup, DISPATCH_TIME_FOREVER);

    if (ok)
    {
        for (int i = 0; i < pageCount && ok; ++i)
        {
            if (pagesPtr[i].hasBackground)
                ok = !pagesPtr[i].background.jp2.empty();
        }
    }

    std::vector<uint8_t> globals;
    std::vector<std::vector<uint8_t>> jbig2Pages;
    if (ok && jb != nullptr)
    {
        int globalsLen = 0;
        uint8_t* globalsBuf = jbig2_pages_complete(jb, &globalsLen);
        if (globalsBuf == nullptr || globalsLen <= 0)
        {
            ok = false;
        }
        else
        {
            globals.assign(globalsBuf, globalsBuf + (size_t)globalsLen);
            free(globalsBuf);
        }

        if (ok)
        {
            jbig2Pages.resize((size_t)pageCount);
            for (int i = 0; i < pageCount && ok; ++i)
            {
                int len = 0;
                uint8_t* pageBuf = jbig2_produce_page(jb, i, -1, -1, &len);
                if (pageBuf == nullptr || len <= 0)
                {
                    ok = false;
                    break;
                }
                jbig2Pages[(size_t)i].assign(pageBuf, pageBuf + (size_t)len);
                free(pageBuf);
            }
        }

        jbig2_destroy(jb);
        jb = nullptr;
    }

    if (ok)
    {
        bool const haveJbig2 = !globals.empty() && !jbig2Pages.empty();
        ok = writePdfDeterministic(tmpPdfPath, pages, haveJbig2 ? &globals : nullptr, haveJbig2 ? &jbig2Pages : nullptr);
    }

    if (jb != nullptr)
        jbig2_destroy(jb);

    ddjvu_format_release(rgb24);
    ddjvu_format_release(grey8);
    ddjvu_format_release(msb);
    ddjvu_document_release(doc);
    ddjvu_context_release(ctx);

    return ok ? YES : NO;
}

#if 0 // Removed: MuPDF/OpenJPEG backend (use Grok+JBIG2 deterministic writer)

enum class DjvuPdfBgFormat
{
    Jpx,
    Jpeg
};

struct DjvuPdfBackground
{
    DjvuPdfBgFormat format = DjvuPdfBgFormat::Jpx;
    bool gray = false;
    int w = 0;
    int h = 0;
    std::vector<uint8_t> bytes;
};

struct DjvuPdfPage
{
    int pageWidth = 0;
    int pageHeight = 0;
    int pageDpi = 0;
    ddjvu_page_type_t pageType = DDJVU_PAGETYPE_BITONAL;

    int renderWidth = 0;
    int renderHeight = 0;
    int targetDpi = 0;

    CGFloat pdfWidth = 0;
    CGFloat pdfHeight = 0;

    bool hasBackground = false;
    DjvuPdfBackground background;

    bool hasMask = false;
};

static NSString* findJbig2encExecutable()
{
    // In GUI apps, PATH is not reliable. Probe common Homebrew locations first.
    static NSArray<NSString*>* candidates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        candidates = @[ @"/opt/homebrew/bin/jbig2enc", @"/usr/local/bin/jbig2enc", @"/usr/bin/jbig2enc" ];
    });

    for (NSString* path in candidates)
    {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path])
            return path;
    }

    return nil;
}

static NSData* pbmP4DataFromBits(int w, int h, size_t rowBytes, unsigned char const* bits)
{
    NSMutableData* data = [NSMutableData data];
    NSString* header = [NSString stringWithFormat:@"P4\n%d %d\n", w, h];
    [data appendData:[header dataUsingEncoding:NSASCIIStringEncoding]];
    [data appendBytes:bits length:rowBytes * (size_t)h];
    return data;
}

static bool renderDjvuMaskPbm(ddjvu_page_t* page, ddjvu_format_t* grey8, ddjvu_format_t* msb, int renderWidth, int renderHeight, bool preferBitonal, NSString* outPath)
{
    ddjvu_rect_t rect = { 0, 0, (unsigned int)renderWidth, (unsigned int)renderHeight };

    // Prefer direct 1-bit output when possible; otherwise render GREY8 and threshold.
    if (preferBitonal)
    {
        size_t rowBytes = ((size_t)renderWidth + 7U) / 8U;
        size_t size = rowBytes * (size_t)renderHeight;
        auto* bits = (unsigned char*)calloc(size, 1);
        if (bits == nullptr)
            return false;

        int const ok = ddjvu_page_render(page, DDJVU_RENDER_MASKONLY, &rect, &rect, msb, (unsigned long)rowBytes, (char*)bits);
        NSData* pbm = ok ? pbmP4DataFromBits(renderWidth, renderHeight, rowBytes, bits) : nil;
        free(bits);
        return pbm != nil && [pbm writeToFile:outPath atomically:YES];
    }

    size_t grayRowBytes = (size_t)renderWidth;
    size_t graySize = grayRowBytes * (size_t)renderHeight;
    auto* gray = (unsigned char*)malloc(graySize);
    if (gray == nullptr)
        return false;
    memset(gray, 0xFF, graySize);

    int const ok = ddjvu_page_render(page, DDJVU_RENDER_MASKONLY, &rect, &rect, grey8, (unsigned long)grayRowBytes, (char*)gray);
    if (!ok)
    {
        free(gray);
        return false;
    }

    size_t bitRowBytes = ((size_t)renderWidth + 7U) / 8U;
    size_t bitSize = bitRowBytes * (size_t)renderHeight;
    auto* bits = (unsigned char*)calloc(bitSize, 1);
    if (bits == nullptr)
    {
        free(gray);
        return false;
    }

    // Mask-only render in GREY8 uses white background with black text. Threshold to 1-bit.
    unsigned char constexpr Threshold = 127;
    for (int y = 0; y < renderHeight; ++y)
    {
        auto const* src = gray + (size_t)y * grayRowBytes;
        auto* dst = bits + (size_t)y * bitRowBytes;
        for (int x = 0; x < renderWidth; ++x)
        {
            if (src[x] < Threshold)
                dst[x / 8] |= (unsigned char)(0x80U >> (x % 8));
        }
    }

    NSData* pbm = pbmP4DataFromBits(renderWidth, renderHeight, bitRowBytes, bits);
    free(bits);
    free(gray);

    return pbm != nil && [pbm writeToFile:outPath atomically:YES];
}

struct OpjMemSink
{
    std::vector<uint8_t> bytes;
};

static OPJ_SIZE_T opjWrite(void* p_buffer, OPJ_SIZE_T p_nb_bytes, void* p_user_data)
{
    auto* sink = static_cast<OpjMemSink*>(p_user_data);
    auto* b = static_cast<uint8_t*>(p_buffer);
    sink->bytes.insert(sink->bytes.end(), b, b + p_nb_bytes);
    return p_nb_bytes;
}

static OPJ_OFF_T opjSkip(OPJ_OFF_T, void*)
{
    return (OPJ_OFF_T)-1;
}

static OPJ_BOOL opjSeek(OPJ_OFF_T, void*)
{
    return OPJ_FALSE;
}

static bool encodeJpxLossless(OpjMemSink* sink, unsigned char const* pixels, int w, int h, size_t stride, bool gray)
{
    opj_cparameters_t params;
    opj_set_default_encoder_parameters(&params);
    params.tcp_numlayers = 1;
    params.cp_disto_alloc = 1;
    params.irreversible = 0; // lossless 5/3
    params.tcp_rates[0] = 0.0f;

    int const comps = gray ? 1 : 3;
    std::vector<opj_image_cmptparm_t> cmpt((size_t)comps);
    for (int c = 0; c < comps; ++c)
    {
        cmpt[c].dx = 1;
        cmpt[c].dy = 1;
        cmpt[c].w = (OPJ_UINT32)w;
        cmpt[c].h = (OPJ_UINT32)h;
        cmpt[c].prec = 8;
        cmpt[c].bpp = 8;
        cmpt[c].sgnd = 0;
    }

    OPJ_COLOR_SPACE cs = gray ? OPJ_CLRSPC_GRAY : OPJ_CLRSPC_SRGB;
    opj_image_t* image = opj_image_create(comps, cmpt.data(), cs);
    if (image == nullptr)
        return false;
    image->x1 = (OPJ_UINT32)w;
    image->y1 = (OPJ_UINT32)h;

    // Convert packed pixels to planar int32 as expected by OpenJPEG.
    if (gray)
    {
        for (int y = 0; y < h; ++y)
        {
            auto const* row = pixels + (size_t)y * stride;
            for (int x = 0; x < w; ++x)
                image->comps[0].data[y * w + x] = row[x];
        }
    }
    else
    {
        for (int y = 0; y < h; ++y)
        {
            auto const* row = pixels + (size_t)y * stride;
            for (int x = 0; x < w; ++x)
            {
                int const idx = y * w + x;
                image->comps[0].data[idx] = row[x * 3 + 0];
                image->comps[1].data[idx] = row[x * 3 + 1];
                image->comps[2].data[idx] = row[x * 3 + 2];
            }
        }
    }

    opj_stream_t* stream = opj_stream_create(64 * 1024, OPJ_FALSE);
    opj_stream_set_user_data(stream, sink, nullptr);
    opj_stream_set_write_function(stream, opjWrite);
    opj_stream_set_skip_function(stream, opjSkip);
    opj_stream_set_seek_function(stream, opjSeek);

    opj_codec_t* codec = opj_create_compress(OPJ_CODEC_JP2);
    bool ok = false;
    if (codec != nullptr)
    {
        if (opj_setup_encoder(codec, &params, image) && opj_start_compress(codec, image, stream) && opj_encode(codec, stream) &&
            opj_end_compress(codec, stream))
        {
            ok = true;
        }
        opj_destroy_codec(codec);
    }

    opj_stream_destroy(stream);
    opj_image_destroy(image);
    return ok;
}

static bool encodeJpegTurbo(std::vector<uint8_t>* out, unsigned char const* pixels, int w, int h, size_t stride, bool gray, int quality)
{
#if HAVE_TURBOJPEG
    tjhandle tj = tjInitCompress();
    if (!tj)
        return false;

    unsigned char* jpegBuf = nullptr;
    unsigned long jpegSize = 0;
    int const pf = gray ? TJPF_GRAY : TJPF_RGB;
    int const subsamp = gray ? TJSAMP_GRAY : TJSAMP_420;
    int const rc = tjCompress2(tj, const_cast<unsigned char*>(pixels), w, (int)stride, h, pf, &jpegBuf, &jpegSize, subsamp, quality, TJFLAG_FASTDCT);
    tjDestroy(tj);

    if (rc == 0 && jpegBuf && jpegSize)
        out->assign(jpegBuf, jpegBuf + jpegSize);

    if (jpegBuf)
        tjFree(jpegBuf);

    return rc == 0 && !out->empty();
#else
    (void)out;
    (void)pixels;
    (void)w;
    (void)h;
    (void)stride;
    (void)gray;
    (void)quality;
    return false;
#endif
}

static bool runJbig2enc(
    NSString* jbig2encPath,
    NSString* workingDir,
    NSArray<NSString*>* pbmPaths,
    std::vector<uint8_t>* globals,
    std::vector<std::vector<uint8_t>>* pages)
{
    if (pbmPaths.count == 0)
        return false;

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:jbig2encPath];
    task.currentDirectoryURL = [NSURL fileURLWithPath:workingDir];

    NSMutableArray<NSString*>* args = [NSMutableArray arrayWithCapacity:pbmPaths.count + 2];
    [args addObject:@"-p"];
    [args addObject:@"-s"];
    [args addObjectsFromArray:pbmPaths];
    task.arguments = args;

    @try
    {
        [task launch];
        [task waitUntilExit];
    }
    @catch (__unused NSException* e)
    {
        return false;
    }

    if (task.terminationStatus != 0)
        return false;

    NSData* globalsData = [NSData dataWithContentsOfFile:[workingDir stringByAppendingPathComponent:@"symboltable"]];
    if (globalsData.length == 0)
        return false;
    globals->assign((uint8_t const*)globalsData.bytes, (uint8_t const*)globalsData.bytes + globalsData.length);

    pages->clear();
    pages->reserve(pbmPaths.count);
    for (NSInteger i = 0; i < (NSInteger)pbmPaths.count; ++i)
    {
        NSString* pageFile = [workingDir stringByAppendingPathComponent:[NSString stringWithFormat:@"page-%ld", (long)i]];
        NSData* pageData = [NSData dataWithContentsOfFile:pageFile];
        if (pageData.length == 0)
            return false;
        pages->emplace_back((uint8_t const*)pageData.bytes, (uint8_t const*)pageData.bytes + pageData.length);
    }

    return true;
}

static bool addMuPdfPage(fz_context* ctx, pdf_document* pdf, pdf_obj* jbig2GlobalsObj, DjvuPdfPage const& page, DjvuPdfBackground const* bg, std::vector<uint8_t> const* maskBytes)
{
    fz_rect media = { 0, 0, (float)page.pdfWidth, (float)page.pdfHeight };

    pdf_obj* resources = pdf_new_dict(ctx, pdf, 8);
    pdf_obj* xobjects = pdf_new_dict(ctx, pdf, 8);
    pdf_dict_puts_drop(ctx, resources, "XObject", xobjects);

    if (bg != nullptr && !bg->bytes.empty())
    {
        pdf_obj* img = pdf_new_dict(ctx, pdf, 16);
        pdf_dict_put(ctx, img, PDF_NAME(Type), PDF_NAME(XObject));
        pdf_dict_put(ctx, img, PDF_NAME(Subtype), PDF_NAME(Image));
        pdf_dict_put_int(ctx, img, PDF_NAME(Width), bg->w);
        pdf_dict_put_int(ctx, img, PDF_NAME(Height), bg->h);
        pdf_dict_put_int(ctx, img, PDF_NAME(BitsPerComponent), 8);
        pdf_dict_put(ctx, img, PDF_NAME(ColorSpace), bg->gray ? PDF_NAME(DeviceGray) : PDF_NAME(DeviceRGB));
        pdf_dict_put(ctx, img, PDF_NAME(Filter), bg->format == DjvuPdfBgFormat::Jpx ? PDF_NAME(JPXDecode) : PDF_NAME(DCTDecode));

        fz_buffer* stream = fz_new_buffer_from_copied_data(ctx, bg->bytes.data(), bg->bytes.size());
        pdf_obj* ref = pdf_add_stream(ctx, pdf, stream, img, 1);
        fz_drop_buffer(ctx, stream);
        pdf_drop_obj(ctx, img);
        pdf_dict_puts_drop(ctx, xobjects, "ImBg", ref);
    }

    if (maskBytes != nullptr && !maskBytes->empty())
    {
        pdf_obj* mask = pdf_new_dict(ctx, pdf, 16);
        pdf_dict_put(ctx, mask, PDF_NAME(Type), PDF_NAME(XObject));
        pdf_dict_put(ctx, mask, PDF_NAME(Subtype), PDF_NAME(Image));
        pdf_dict_put_int(ctx, mask, PDF_NAME(Width), page.renderWidth);
        pdf_dict_put_int(ctx, mask, PDF_NAME(Height), page.renderHeight);
        pdf_dict_put_int(ctx, mask, PDF_NAME(BitsPerComponent), 1);
        pdf_dict_put_bool(ctx, mask, PDF_NAME(ImageMask), 1);
        pdf_dict_put(ctx, mask, PDF_NAME(Filter), PDF_NAME(JBIG2Decode));

        pdf_obj* dp = pdf_new_dict(ctx, pdf, 2);
        pdf_dict_put(ctx, dp, PDF_NAME(JBIG2Globals), jbig2GlobalsObj);
        pdf_dict_put_drop(ctx, mask, PDF_NAME(DecodeParms), dp);

        fz_buffer* stream = fz_new_buffer_from_copied_data(ctx, maskBytes->data(), maskBytes->size());
        pdf_obj* ref = pdf_add_stream(ctx, pdf, stream, mask, 1);
        fz_drop_buffer(ctx, stream);
        pdf_drop_obj(ctx, mask);
        pdf_dict_puts_drop(ctx, xobjects, "ImM", ref);
    }

    // Content stream: draw background (if any), then stencil mask in black (if any).
    fz_buffer* contents = fz_new_buffer(ctx, 256);
    fz_append_printf(ctx, contents, "q\n%g 0 0 %g 0 0 cm\n", page.pdfWidth, page.pdfHeight);
    if (bg != nullptr && !bg->bytes.empty())
        fz_append_printf(ctx, contents, "/ImBg Do\n");
    if (maskBytes != nullptr && !maskBytes->empty())
        fz_append_printf(ctx, contents, "0 g\n/ImM Do\n");
    fz_append_printf(ctx, contents, "Q\n");

    pdf_obj* pageObj = pdf_add_page(ctx, pdf, media, 0, resources, contents);
    pdf_insert_page(ctx, pdf, -1, pageObj);
    pdf_drop_obj(ctx, pageObj);
    pdf_drop_obj(ctx, resources);
    fz_drop_buffer(ctx, contents);
    return true;
}

static bool writePdfMuPdf(
    NSString* tmpPdfPath,
    std::vector<DjvuPdfPage> const& pages,
    std::vector<uint8_t> const& globals,
    std::vector<std::vector<uint8_t>> const& jbig2Pages)
{
    bool ok = false;
    fz_context* ctx = nullptr;
    pdf_document* pdf = nullptr;

    ctx = fz_new_context(nullptr, nullptr, FZ_STORE_UNLIMITED);
    if (ctx == nullptr)
        return false;

    fz_try(ctx)
    {
        pdf = pdf_create_document(ctx);

        // JBIG2Globals stream (raw segment data). Kept as an indirect object.
        fz_buffer* globalsBuf = fz_new_buffer_from_copied_data(ctx, globals.data(), globals.size());
        pdf_obj* globalsDict = pdf_new_dict(ctx, pdf, 0);
        pdf_obj* globalsObj = pdf_add_stream(ctx, pdf, globalsBuf, globalsDict, 0);
        fz_drop_buffer(ctx, globalsBuf);
        pdf_drop_obj(ctx, globalsDict);

        for (size_t i = 0; i < pages.size(); ++i)
        {
            DjvuPdfPage const& p = pages[i];
            DjvuPdfBackground const* bg = p.hasBackground ? &p.background : nullptr;
            std::vector<uint8_t> const* mask = (p.hasMask && i < jbig2Pages.size()) ? &jbig2Pages[i] : nullptr;
            (void)addMuPdfPage(ctx, pdf, globalsObj, p, bg, mask);
        }

        fz_output* out = fz_new_output_with_path(ctx, tmpPdfPath.UTF8String, 0);
        pdf_write_options opts = pdf_default_write_options;
        opts.do_compress = 1;
        opts.do_compress_images = 0;
        pdf_write_document(ctx, pdf, out, &opts);
        fz_close_output(ctx, out);
        fz_drop_output(ctx, out);

        pdf_drop_obj(ctx, globalsObj);
        ok = true;
    }
    fz_always(ctx)
    {
        if (pdf != nullptr)
            pdf_drop_document(ctx, pdf);
        fz_drop_context(ctx);
    }
    fz_catch(ctx)
    {
        ok = false;
    }

    return ok;
}

#endif // 0

@implementation DjvuConverter

+ (void)initialize
{
    if (self == [DjvuConverter class])
    {
        sConversionQueue = [NSMutableDictionary dictionary];
        sLastScanTime = [NSMutableDictionary dictionary];
        dispatch_queue_attr_t attrs = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        sConversionDispatchQueue = dispatch_queue_create("com.transmissionbt.djvuconverter", attrs);
    }
}

+ (void)checkAndConvertCompletedFiles:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return;

    NSString* torrentHash = torrent.hashString;

    // Throttle scans: this method is called frequently during UI updates.
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSNumber* lastScan = sLastScanTime[torrentHash];
    if (lastScan != nil && now - lastScan.doubleValue < 5.0)
        return;
    sLastScanTime[torrentHash] = @(now);

    NSArray<FileListNode*>* fileList = torrent.flatFileList;

    // Get or create tracking set for this torrent
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];
    if (!queuedFiles)
    {
        queuedFiles = [NSMutableSet set];
        sConversionQueue[torrentHash] = queuedFiles;
    }

    // Collect PDF base names already in the torrent (no need to convert if torrent has PDF)
    NSMutableSet<NSString*>* pdfBaseNames = [NSMutableSet set];
    for (FileListNode* node in fileList)
    {
        if ([node.name.pathExtension.lowercaseString isEqualToString:@"pdf"])
        {
            [pdfBaseNames addObject:node.name.stringByDeletingPathExtension.lowercaseString];
        }
    }

    NSMutableArray<NSDictionary*>* filesToConvert = [NSMutableArray array];

    for (FileListNode* node in fileList)
    {
        NSString* name = node.name;
        NSString* ext = name.pathExtension.lowercaseString;

        // Only process DJVU files
        if (![ext isEqualToString:@"djvu"] && ![ext isEqualToString:@"djv"])
            continue;

        // Skip if torrent already contains a PDF with the same base name
        NSString* baseName = name.stringByDeletingPathExtension.lowercaseString;
        if ([pdfBaseNames containsObject:baseName])
            continue;

        // Check if file is 100% complete
        CGFloat progress = [torrent fileProgress:node];
        if (progress < 1.0)
            continue;

        NSString* path = [torrent fileLocation:node];
        if (!path)
            continue;

        NSString* pdfPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];

        // Check if PDF already exists on disk (converted previously)
        if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
        {
            [queuedFiles addObject:path];
            continue;
        }

        // Skip if already queued for conversion
        if ([queuedFiles containsObject:path])
            continue;

        // Mark as queued and add to conversion list
        [queuedFiles addObject:path];
        [filesToConvert addObject:@{ @"djvu" : path, @"pdf" : pdfPath }];
    }

    if (filesToConvert.count == 0)
        return;

    // Copy torrentHash to ensure it's retained for the notification block
    NSString* notificationObject = [torrentHash copy];

    // Use dispatch group to notify when all conversions complete
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary* file in filesToConvert)
    {
        dispatch_group_async(group, sConversionDispatchQueue, ^{
            @autoreleasepool
            {
                NSString* djvuPath = file[@"djvu"];
                NSString* pdfPath = file[@"pdf"];

                // Skip if PDF already exists
                if (![NSFileManager.defaultManager fileExistsAtPath:pdfPath])
                {
                    [self convertDjvuFile:djvuPath toPdf:pdfPath];
                }
            }
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"DjvuConversionComplete" object:notificationObject];
    });
}

+ (void)clearTrackingForTorrent:(Torrent*)torrent
{
    if (!torrent)
        return;

    [sLastScanTime removeObjectForKey:torrent.hashString];
    [sConversionQueue removeObjectForKey:torrent.hashString];
}

+ (NSString*)convertingFileNameForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return nil;

    // Ensure static variables are initialized
    if (!sConversionQueue || !sConversionDispatchQueue)
        return nil;

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];

    if (!queuedFiles || queuedFiles.count == 0)
        return nil;

    // Find the first file that is actively converting and PDF doesn't exist yet
    for (NSString* djvuPath in queuedFiles)
    {
        if (![sActiveConversions containsObject:djvuPath])
            continue;

        NSString* pdfPath = [djvuPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
        if (![NSFileManager.defaultManager fileExistsAtPath:pdfPath])
        {
            // Return the filename (last path component)
            return djvuPath.lastPathComponent;
        }
    }

    return nil;
}

// Track files currently being converted (to avoid duplicate dispatches)
static NSMutableSet<NSString*>* sActiveConversions = nil;
// Track files pending dispatch (queued but not yet running)
static NSMutableSet<NSString*>* sPendingConversions = nil;
// Track files that failed to convert (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sFailedConversions = nil;
// Track per-file page progress (djvu path -> counts)
static NSMutableDictionary<NSString*, NSNumber*>* sConversionTotalPages = nil;
static NSMutableDictionary<NSString*, NSNumber*>* sConversionDonePages = nil;

// Forward declarations for per-file page tracking helpers
static void setTotalPagesForPath(NSString* djvuPath, int total);
static void incrementDonePagesForPath(NSString* djvuPath);
static void clearPageTrackingForPath(NSString* djvuPath);

static void setTotalPagesForPath(NSString* djvuPath, int total)
{
    if (!djvuPath || total <= 0)
        return;
    @synchronized(sConversionTotalPages)
    {
        sConversionTotalPages[djvuPath] = @(total);
    }
    @synchronized(sConversionDonePages)
    {
        sConversionDonePages[djvuPath] = @0;
    }
}

static void incrementDonePagesForPath(NSString* djvuPath)
{
    if (!djvuPath)
        return;
    @synchronized(sConversionDonePages)
    {
        NSNumber* current = sConversionDonePages[djvuPath];
        if (current != nil)
        {
            sConversionDonePages[djvuPath] = @([current integerValue] + 1);
        }
    }
}

static void clearPageTrackingForPath(NSString* djvuPath)
{
    if (!djvuPath)
        return;
    @synchronized(sConversionTotalPages)
    {
        [sConversionTotalPages removeObjectForKey:djvuPath];
    }
    @synchronized(sConversionDonePages)
    {
        [sConversionDonePages removeObjectForKey:djvuPath];
    }
}

+ (void)ensureConversionDispatchedForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return;

    if (!sConversionQueue || !sConversionDispatchQueue)
        return;

    if (!sActiveConversions)
        sActiveConversions = [NSMutableSet set];
    if (!sFailedConversions)
        sFailedConversions = [NSMutableDictionary dictionary];
    if (!sPendingConversions)
        sPendingConversions = [NSMutableSet set];
    if (!sConversionTotalPages)
        sConversionTotalPages = [NSMutableDictionary dictionary];
    if (!sConversionDonePages)
        sConversionDonePages = [NSMutableDictionary dictionary];

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];

    if (!queuedFiles || queuedFiles.count == 0)
        return;

    NSMutableSet<NSString*>* failedForTorrent = sFailedConversions[torrentHash];
    if (!failedForTorrent)
    {
        failedForTorrent = [NSMutableSet set];
        sFailedConversions[torrentHash] = failedForTorrent;
    }

    // Find files that are queued but not actively being converted
    NSMutableArray<NSDictionary*>* filesToDispatch = [NSMutableArray array];

    for (NSString* djvuPath in queuedFiles)
    {
        NSString* pdfPath = [djvuPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];

        // Skip if PDF already exists or conversion is already active/pending
        if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
            continue;
        if ([sActiveConversions containsObject:djvuPath])
            continue;
        if ([sPendingConversions containsObject:djvuPath])
            continue;
        if ([failedForTorrent containsObject:djvuPath])
            continue;

        [sPendingConversions addObject:djvuPath];
        [filesToDispatch addObject:@{ @"djvu" : djvuPath, @"pdf" : pdfPath }];
    }

    if (filesToDispatch.count == 0)
        return;

    NSString* notificationObject = [torrentHash copy];

    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary* file in filesToDispatch)
    {
        dispatch_group_async(group, sConversionDispatchQueue, ^{
            @autoreleasepool
            {
                NSString* djvuPath = file[@"djvu"];
                NSString* pdfPath = file[@"pdf"];
                BOOL success = YES;

                // Mark active when the worker actually begins
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [sActiveConversions addObject:djvuPath];
                });

                if (![NSFileManager.defaultManager fileExistsAtPath:pdfPath])
                {
                    success = [self convertDjvuFile:djvuPath toPdf:pdfPath];
                }

                // Remove from active set when done
                dispatch_async(dispatch_get_main_queue(), ^{
                    [sActiveConversions removeObject:djvuPath];
                    [sPendingConversions removeObject:djvuPath];
                    if (success)
                    {
                        [failedForTorrent removeObject:djvuPath];
                        clearPageTrackingForPath(djvuPath);
                    }
                    else
                    {
                        [failedForTorrent addObject:djvuPath];
                        clearPageTrackingForPath(djvuPath);
                    }
                });
            }
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"DjvuConversionComplete" object:notificationObject];
    });
}

+ (NSString*)failedConversionFileNameForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return nil;

    if (!sFailedConversions)
        return nil;

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* failedFiles = sFailedConversions[torrentHash];
    if (!failedFiles || failedFiles.count == 0)
        return nil;

    for (NSString* djvuPath in failedFiles)
    {
        // If a PDF exists now, clear the failure entry
        NSString* pdfPath = [djvuPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
        if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
        {
            [failedFiles removeObject:djvuPath];
            continue;
        }

        return djvuPath.lastPathComponent;
    }

    return nil;
}

+ (NSString*)convertingProgressForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return nil;

    if (!sConversionQueue || !sConversionTotalPages || !sConversionDonePages)
        return nil;

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];

    if (!queuedFiles || queuedFiles.count == 0)
        return nil;

    for (NSString* djvuPath in queuedFiles)
    {
        if (![sActiveConversions containsObject:djvuPath])
            continue;

        NSNumber* total = nil;
        NSNumber* done = nil;
        @synchronized(sConversionTotalPages)
        {
            total = sConversionTotalPages[djvuPath];
        }
        @synchronized(sConversionDonePages)
        {
            done = sConversionDonePages[djvuPath];
        }

        if (total != nil && total.intValue > 0 && done != nil)
        {
            int totalPages = total.intValue;
            int donePages = done.intValue;
            if (donePages < 0)
                donePages = 0;
            if (donePages > totalPages)
                donePages = totalPages;
            return [NSString stringWithFormat:@"%d of %d pages", donePages, totalPages];
        }
    }

    return nil;
}

#if HAVE_MUPDF && HAVE_OPENJPEG

static bool isGrayscaleRgb24(unsigned char const* rgb, int width, int height, size_t rowBytes)
{
    int stepX = MAX(1, width / 512);
    int stepY = MAX(1, height / 512);

    for (int y = 0; y < height; y += stepY)
    {
        auto const* row = rgb + (size_t)y * rowBytes;
        for (int x = 0; x < width; x += stepX)
        {
            unsigned char r = row[x * 3 + 0];
            unsigned char g = row[x * 3 + 1];
            unsigned char b = row[x * 3 + 2];
            if (abs((int)r - (int)g) > 2 || abs((int)r - (int)b) > 2)
                return false;
        }
    }

    return true;
}

static BOOL convertDjvuFileWithMuPdf(NSString* djvuPath, NSString* tmpPdfPath)
{
    NSString* jbig2enc = findJbig2encExecutable();
    if (jbig2enc == nil)
        return NO;

    NSString* workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil])
        return NO;

    ddjvu_context_t* ctx = ddjvu_context_create("Transmission");
    if (!ctx)
    {
        [NSFileManager.defaultManager removeItemAtPath:workDir error:nil];
        return NO;
    }

    ddjvu_document_t* doc = ddjvu_document_create_by_filename_utf8(ctx, djvuPath.UTF8String, TRUE);
    if (!doc)
    {
        ddjvu_context_release(ctx);
        [NSFileManager.defaultManager removeItemAtPath:workDir error:nil];
        return NO;
    }

    while (!ddjvu_document_decoding_done(doc))
    {
        ddjvu_message_t* msg = ddjvu_message_wait(ctx);
        if (msg)
            ddjvu_message_pop(ctx);
    }

    if (ddjvu_document_decoding_error(doc))
    {
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        [NSFileManager.defaultManager removeItemAtPath:workDir error:nil];
        return NO;
    }

    int pageCount = ddjvu_document_get_pagenum(doc);
    if (pageCount <= 0)
    {
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        [NSFileManager.defaultManager removeItemAtPath:workDir error:nil];
        return NO;
    }

    ddjvu_format_t* rgb24 = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, nullptr);
    ddjvu_format_t* grey8 = ddjvu_format_create(DDJVU_FORMAT_GREY8, 0, nullptr);
    ddjvu_format_t* msb = ddjvu_format_create(DDJVU_FORMAT_MSBTOLSB, 0, nullptr);
    if (!rgb24 || !grey8 || !msb)
    {
        if (rgb24)
            ddjvu_format_release(rgb24);
        if (grey8)
            ddjvu_format_release(grey8);
        if (msb)
            ddjvu_format_release(msb);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        [NSFileManager.defaultManager removeItemAtPath:workDir error:nil];
        return NO;
    }

    ddjvu_format_set_row_order(rgb24, TRUE);
    ddjvu_format_set_y_direction(rgb24, TRUE);
    ddjvu_format_set_row_order(grey8, TRUE);
    ddjvu_format_set_y_direction(grey8, TRUE);
    ddjvu_format_set_row_order(msb, TRUE);
    ddjvu_format_set_y_direction(msb, TRUE);

    std::vector<DjvuPdfPage> pages((size_t)pageCount);
    DjvuPdfPage* pagesPtr = pages.data();

    NSMutableArray<NSString*>* pbmPaths = [NSMutableArray arrayWithCapacity:(NSUInteger)pageCount];

    dispatch_queue_t encQ = dispatch_queue_create("transmission.djvu.jp2.encode", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t encGroup = dispatch_group_create();

    NSInteger cpu = NSProcessInfo.processInfo.activeProcessorCount;
    NSInteger maxConcurrent = MAX(1, MIN(cpu, 4));
    dispatch_semaphore_t sem = dispatch_semaphore_create(maxConcurrent);

    bool ok = true;

    for (int pageNum = 0; pageNum < pageCount && ok; ++pageNum)
    {
        @autoreleasepool
        {
            ddjvu_page_t* page = ddjvu_page_create_by_pageno(doc, pageNum);
            if (!page)
            {
                ok = false;
                break;
            }

            while (!ddjvu_page_decoding_done(page))
            {
                ddjvu_message_t* msg = ddjvu_message_wait(ctx);
                if (msg)
                    ddjvu_message_pop(ctx);
            }

            if (ddjvu_page_decoding_error(page))
            {
                ddjvu_page_release(page);
                ok = false;
                break;
            }

            ddjvu_page_type_t pageType = ddjvu_page_get_type(page);
            int pageWidth = ddjvu_page_get_width(page);
            int pageHeight = ddjvu_page_get_height(page);
            int pageDpi = ddjvu_page_get_resolution(page);
            if (pageWidth <= 0 || pageHeight <= 0 || pageDpi <= 0)
            {
                ddjvu_page_release(page);
                ok = false;
                break;
            }

            DjvuPdfPage& p = pagesPtr[pageNum];
            p.pageWidth = pageWidth;
            p.pageHeight = pageHeight;
            p.pageDpi = pageDpi;
            p.pageType = pageType;
            p.pdfWidth = (CGFloat)pageWidth * 72.0 / (CGFloat)pageDpi;
            p.pdfHeight = (CGFloat)pageHeight * 72.0 / (CGFloat)pageDpi;

            int constexpr BgMaxDpi = 200;
            int constexpr MaskMaxDpi = 300;

            int bgDpi = MIN(BgMaxDpi, pageDpi);
            int maskDpi = MIN(MaskMaxDpi, pageDpi);

            // Background (JPXDecode) for photo/compound pages
            if (pageType == DDJVU_PAGETYPE_PHOTO || pageType == DDJVU_PAGETYPE_COMPOUND)
            {
                int bgW = 0;
                int bgH = 0;
                computeRenderDimensions(pageWidth, pageHeight, pageDpi, bgDpi, &bgW, &bgH);

                size_t rowBytes = (size_t)bgW * 3;
                std::shared_ptr<std::vector<uint8_t>> rgb = std::make_shared<std::vector<uint8_t>>(rowBytes * (size_t)bgH, (uint8_t)0xFF);

                ddjvu_rect_t rect = { 0, 0, (unsigned int)bgW, (unsigned int)bgH };
                int rendered = ddjvu_page_render(
                    page,
                    pageType == DDJVU_PAGETYPE_COMPOUND ? DDJVU_RENDER_BACKGROUND : DDJVU_RENDER_COLOR,
                    &rect,
                    &rect,
                    rgb24,
                    (unsigned long)rowBytes,
                    (char*)rgb->data());

                if (!rendered && pageType == DDJVU_PAGETYPE_COMPOUND)
                {
                    // Some files don't expose background separately; fall back to full render.
                    rendered = ddjvu_page_render(
                        page,
                        DDJVU_RENDER_COLOR,
                        &rect,
                        &rect,
                        rgb24,
                        (unsigned long)rowBytes,
                        (char*)rgb->data());
                }

                if (!rendered)
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }

                bool const gray = isGrayscaleRgb24(rgb->data(), bgW, bgH, rowBytes);
                p.hasBackground = true;
                p.background.w = bgW;
                p.background.h = bgH;
                p.background.gray = gray;
                p.background.format = DjvuPdfBgFormat::Jpx;

                dispatch_group_async(encGroup, encQ, ^{
                    @autoreleasepool
                    {
                        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

                        DjvuPdfBackground bg;
                        bg.w = bgW;
                        bg.h = bgH;
                        bg.gray = gray;
                        bg.format = DjvuPdfBgFormat::Jpx;

                        OpjMemSink sink;
                        std::vector<uint8_t> grayBuf;
                        unsigned char const* src = rgb->data();
                        size_t srcStride = rowBytes;
                        if (gray)
                        {
                            grayBuf.resize((size_t)bgW * (size_t)bgH);
                            for (int y = 0; y < bgH; ++y)
                            {
                                auto const* srcRow = rgb->data() + (size_t)y * rowBytes;
                                auto* dst = grayBuf.data() + (size_t)y * (size_t)bgW;
                                for (int x = 0; x < bgW; ++x)
                                    dst[x] = srcRow[x * 3 + 0];
                            }
                            src = grayBuf.data();
                            srcStride = (size_t)bgW;
                        }

                        bool encoded = encodeJpxLossless(&sink, src, bgW, bgH, srcStride, gray);

                        if (encoded)
                        {
                            bg.bytes = std::move(sink.bytes);
                        }
                        else if (encodeJpegTurbo(&bg.bytes, src, bgW, bgH, srcStride, gray, 80))
                        {
                            bg.format = DjvuPdfBgFormat::Jpeg;
                            encoded = true;
                        }

                        if (encoded)
                            pagesPtr[pageNum].background = std::move(bg);
                        else
                            pagesPtr[pageNum].hasBackground = false;

                        dispatch_semaphore_signal(sem);
                    }
                });
            }

            // Mask (JBIG2Decode) for bitonal/compound pages
            if (pageType == DDJVU_PAGETYPE_BITONAL || pageType == DDJVU_PAGETYPE_COMPOUND)
            {
                int maskW = 0;
                int maskH = 0;
                computeRenderDimensions(pageWidth, pageHeight, pageDpi, maskDpi, &maskW, &maskH);

                // Only attempt direct 1-bit when unscaled at source resolution.
                bool const preferBitonal = (maskDpi == pageDpi) && (maskW == pageWidth) && (maskH == pageHeight);

                NSString* pbmPath = [workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"mask-%d.pbm", pageNum]];
                if (!renderDjvuMaskPbm(page, grey8, msb, maskW, maskH, preferBitonal, pbmPath))
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }

                [pbmPaths addObject:pbmPath];
                p.hasMask = true;
                p.renderWidth = maskW;
                p.renderHeight = maskH;
                p.targetDpi = maskDpi;
            }
            else
            {
                // Keep page index alignment for jbig2enc outputs.
                NSString* pbmPath = [workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"mask-%d.pbm", pageNum]];
                unsigned char zero = 0;
                NSData* pbm = pbmP4DataFromBits(1, 1, 1, &zero);
                if (![pbm writeToFile:pbmPath atomically:YES])
                {
                    ddjvu_page_release(page);
                    ok = false;
                    break;
                }
                [pbmPaths addObject:pbmPath];
                p.hasMask = false;
            }

            ddjvu_page_release(page);
        }
    }

    dispatch_group_wait(encGroup, DISPATCH_TIME_FOREVER);

    if (ok && pbmPaths.count == (NSUInteger)pageCount)
    {
        // Ensure required background images were successfully encoded.
        for (int i = 0; i < pageCount && ok; ++i)
        {
            if (pagesPtr[i].pageType == DDJVU_PAGETYPE_PHOTO || pagesPtr[i].pageType == DDJVU_PAGETYPE_COMPOUND)
            {
                ok = pagesPtr[i].hasBackground && !pagesPtr[i].background.bytes.empty();
            }
        }

        if (ok)
        {
            std::vector<uint8_t> globals;
            std::vector<std::vector<uint8_t>> jbig2Pages;
            ok = runJbig2enc(jbig2enc, workDir, pbmPaths, &globals, &jbig2Pages) && writePdfMuPdf(tmpPdfPath, pages, globals, jbig2Pages);
        }
    }
    else
    {
        ok = false;
    }

    ddjvu_format_release(rgb24);
    ddjvu_format_release(grey8);
    ddjvu_format_release(msb);
    ddjvu_document_release(doc);
    ddjvu_context_release(ctx);
    [NSFileManager.defaultManager removeItemAtPath:workDir error:nil];
    return ok ? YES : NO;
}

#endif // HAVE_MUPDF && HAVE_OPENJPEG

+ (BOOL)convertDjvuFile:(NSString*)djvuPath toPdf:(NSString*)pdfPath
{
    NSString* tmpPdfPath = [pdfPath stringByAppendingFormat:@".tmp-%@", NSUUID.UUID.UUIDString];

    BOOL success = convertDjvuFileDeterministic(djvuPath, tmpPdfPath);
    if (!success)
    {
        [NSFileManager.defaultManager removeItemAtPath:tmpPdfPath error:nil];
        return NO;
    }

    // Replace destination atomically to avoid ever exposing a partial PDF.
    [NSFileManager.defaultManager removeItemAtPath:pdfPath error:nil];
    if (![NSFileManager.defaultManager moveItemAtPath:tmpPdfPath toPath:pdfPath error:nil])
    {
        [NSFileManager.defaultManager removeItemAtPath:tmpPdfPath error:nil];
        return NO;
    }

    return YES;
}

@end
