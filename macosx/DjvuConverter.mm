// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "DjvuConverter.h"
#import "Torrent.h"
#import "FileListNode.h"

#import <ddjvuapi.h>

#include <miniexp.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
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

enum class DjvuPdfImageKind
{
    None,
    Jp2,
    Jbig2
};

struct DjvuPdfImageInfo
{
    DjvuPdfImageKind kind = DjvuPdfImageKind::None;
    bool gray = false;
    int w = 0;
    int h = 0;
    int jbig2GlobalsIndex = -1;

    // Placement in PDF user space (points).
    double x = 0.0;
    double y = 0.0;
    double pdfW = 0.0;
    double pdfH = 0.0;

    // Encoded bytes. For JP2: JPXDecode stream. For JBIG2: JBIG2Decode page stream.
    std::vector<uint8_t> bytes;
};

struct DjvuPdfPageInfo
{
    double pdfWidth = 0.0;
    double pdfHeight = 0.0;
    DjvuPdfImageInfo image;
    // For compound pages: background picture layer + foreground text mask overlay
    DjvuPdfImageInfo bgImage; // Background: JP2 grayscale/RGB
    DjvuPdfImageInfo fgMask; // JBIG2 ImageMask (transparent bg)
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

// Check if grayscale RGB image is bitonal - reads R channel directly (avoids gray buffer creation)
static bool isBitonalGrayscaleRgb(unsigned char const* rgb, int width, int height, size_t rowBytes)
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
        auto const* row = rgb + (size_t)y * rowBytes;
        int const ty = (y * TileCount) / height;
        for (int x = 0; x < width; x += stepX)
        {
            int const tx = (x * TileCount) / width;
            size_t const tileIdx = (size_t)ty * (size_t)TileCount + (size_t)tx;
            ++tileSamples[tileIdx];

            // Read R channel (for grayscale RGB, R=G=B)
            unsigned char const v = row[x * 3];
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

    // Reject "photo-like" pages with localized dense dark regions
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

struct CropRect
{
    int x0 = 0;
    int y0 = 0;
    int x1 = 0; // exclusive
    int y1 = 0; // exclusive
};

struct OutlineNode
{
    std::string title;
    int rawPage = -1; // numeric page reference when not directly resolved
    int pageIndex = -1; // resolved 0-based page index
    std::vector<OutlineNode> children;
};

using PageTargetMap = std::unordered_map<std::string, int>;

static void padCropRect(CropRect* r, int pad, int w, int h)
{
    if (r == nullptr)
        return;

    r->x0 = MAX(0, r->x0 - pad);
    r->y0 = MAX(0, r->y0 - pad);
    r->x1 = MIN(w, r->x1 + pad);
    r->y1 = MIN(h, r->y1 + pad);
}

// Convert RGB24 buffer to grayscale (optimized version)
static std::vector<unsigned char> rgb24ToGrayscale(unsigned char const* rgb, int w, int h, size_t rowBytes)
{
    std::vector<unsigned char> gray(w * (size_t)h);
    for (int y = 0; y < h; ++y)
    {
        auto const* srcRow = rgb + (size_t)y * rowBytes;
        auto* dst = gray.data() + (size_t)y * (size_t)w;
        for (int x = 0; x < w; ++x)
            dst[x] = srcRow[x * 3];
    }
    return gray;
}

// Extract cropped region from RGB24 buffer
static std::vector<uint8_t> extractRgbCrop(unsigned char const* rgb, size_t fullRowBytes, CropRect const& crop)
{
    int cropW = crop.x1 - crop.x0;
    int cropH = crop.y1 - crop.y0;
    size_t const cropRowBytes = (size_t)cropW * 3U;
    std::vector<uint8_t> cropped(cropRowBytes * (size_t)cropH);
    for (int y = 0; y < cropH; ++y)
    {
        auto const* srcRow = rgb + (size_t)(crop.y0 + y) * fullRowBytes + (size_t)crop.x0 * 3U;
        memcpy(cropped.data() + (size_t)y * cropRowBytes, srcRow, cropRowBytes);
    }
    return cropped;
}

// Extract cropped region from grayscale buffer
static std::vector<uint8_t> extractGrayCrop(unsigned char const* gray, int fullW, CropRect const& crop)
{
    int cropW = crop.x1 - crop.x0;
    int cropH = crop.y1 - crop.y0;
    std::vector<uint8_t> cropped((size_t)cropW * (size_t)cropH);
    for (int y = 0; y < cropH; ++y)
    {
        auto const* srcRow = gray + (size_t)(crop.y0 + y) * (size_t)fullW + (size_t)crop.x0;
        memcpy(cropped.data() + (size_t)y * (size_t)cropW, srcRow, (size_t)cropW);
    }
    return cropped;
}

static int parseOutlinePageNumber(std::string_view url)
{
    size_t const hashPos = url.find('#');
    if (hashPos == std::string_view::npos)
        return -1;

    char const* start = url.data() + hashPos + 1;
    if (start >= url.data() + url.size() || !std::isdigit((unsigned char)*start))
        return -1;

    char* end = nullptr;
    long const page = std::strtol(start, &end, 10);
    if (end == start || page < 0)
        return -1;

    return (int)page;
}

static bool decodeHex(char c, unsigned char* out)
{
    if (out == nullptr)
        return false;
    if (c >= '0' && c <= '9')
    {
        *out = (unsigned char)(c - '0');
        return true;
    }
    if (c >= 'a' && c <= 'f')
    {
        *out = (unsigned char)(10 + (c - 'a'));
        return true;
    }
    if (c >= 'A' && c <= 'F')
    {
        *out = (unsigned char)(10 + (c - 'A'));
        return true;
    }
    return false;
}

static std::string decodeUrlValue(std::string_view value)
{
    std::string out;
    out.reserve(value.size());
    for (size_t i = 0; i < value.size(); ++i)
    {
        char const ch = value[i];
        if (ch == '%' && i + 2 < value.size())
        {
            unsigned char hi = 0;
            unsigned char lo = 0;
            if (decodeHex(value[i + 1], &hi) && decodeHex(value[i + 2], &lo))
            {
                out.push_back((char)((hi << 4) | lo));
                i += 2;
                continue;
            }
        }
        if (ch == '+')
            out.push_back(' ');
        else
            out.push_back(ch);
    }
    return out;
}

static std::string extractOutlineTarget(std::string_view url)
{
    if (url.empty())
        return {};

    if (url[0] == '#')
        return decodeUrlValue(url.substr(1));

    size_t qpos = url.find('?');
    if (qpos == std::string_view::npos)
        return {};

    std::string_view query = url.substr(qpos + 1);
    while (!query.empty())
    {
        size_t const amp = query.find('&');
        std::string_view param = amp == std::string_view::npos ? query : query.substr(0, amp);
        size_t const eq = param.find('=');
        if (eq != std::string_view::npos)
        {
            std::string_view key = param.substr(0, eq);
            std::string_view val = param.substr(eq + 1);
            if (key == "page" || key == "p")
                return decodeUrlValue(val);
        }
        if (amp == std::string_view::npos)
            break;
        query = query.substr(amp + 1);
    }

    return {};
}

static PageTargetMap buildPageTargetMap(ddjvu_context_t* ctx, ddjvu_document_t* doc)
{
    PageTargetMap map;
    if (ctx == nullptr || doc == nullptr)
        return map;

    int filenum = ddjvu_document_get_filenum(doc);
    while (filenum == 0)
    {
        ddjvu_message_t* msg = ddjvu_message_wait(ctx);
        if (msg)
            ddjvu_message_pop(ctx);
        filenum = ddjvu_document_get_filenum(doc);
    }

    if (filenum <= 0)
        return map;

    ddjvu_fileinfo_t info{};
    for (int i = 0; i < filenum; ++i)
    {
        ddjvu_status_t status = ddjvu_document_get_fileinfo(doc, i, &info);
        while (status < DDJVU_JOB_OK)
        {
            ddjvu_message_t* msg = ddjvu_message_wait(ctx);
            if (msg)
                ddjvu_message_pop(ctx);
            status = ddjvu_document_get_fileinfo(doc, i, &info);
        }

        if (status >= DDJVU_JOB_FAILED)
            continue;
        if (info.type != 'P' || info.pageno < 0)
            continue;

        int const pageIndex = info.pageno;
        if (info.name != nullptr && info.name[0] != '\0')
            map.emplace(info.name, pageIndex);
        if (info.title != nullptr && info.title[0] != '\0')
            map.emplace(info.title, pageIndex);
    }

    return map;
}

static int resolveOutlineTarget(ddjvu_document_t* doc, PageTargetMap const& map, std::string const& target)
{
    auto it = map.find(target);
    if (it != map.end())
        return it->second;

    if (doc != nullptr)
    {
        int const resolved = ddjvu_document_search_pageno(doc, target.c_str());
        if (resolved >= 0)
            return resolved;
    }

    return -1;
}

static bool parseOutlineEntry(ddjvu_document_t* doc, PageTargetMap const& map, miniexp_t entry, OutlineNode* out)
{
    if (out == nullptr || doc == nullptr || !miniexp_consp(entry))
        return false;

    miniexp_t titleExp = miniexp_car(entry);
    miniexp_t urlExp = miniexp_cadr(entry);
    if (!miniexp_stringp(titleExp) || !miniexp_stringp(urlExp))
        return false;

    char const* title = miniexp_to_str(titleExp);
    char const* url = miniexp_to_str(urlExp);
    if (title == nullptr || url == nullptr)
        return false;

    std::string const target = extractOutlineTarget(url);
    if (target.empty())
        return false;

    OutlineNode node;
    node.title = title;
    int const resolved = resolveOutlineTarget(doc, map, target);
    if (resolved >= 0)
    {
        node.pageIndex = resolved;
    }
    else
    {
        int const rawPage = parseOutlinePageNumber(target);
        if (rawPage < 0)
            return false;
        node.rawPage = rawPage;
    }

    miniexp_t rest = miniexp_cddr(entry);
    while (miniexp_consp(rest))
    {
        miniexp_t childExp = miniexp_car(rest);
        OutlineNode child;
        if (parseOutlineEntry(doc, map, childExp, &child))
            node.children.push_back(std::move(child));
        rest = miniexp_cdr(rest);
    }

    *out = std::move(node);
    return true;
}

static void applyOutlineOffset(std::vector<OutlineNode>* nodes, int offset, int pageCount)
{
    if (nodes == nullptr)
        return;

    for (auto& node : *nodes)
    {
        if (node.pageIndex < 0 && node.rawPage >= 0)
        {
            node.pageIndex = node.rawPage - offset;
            if (node.pageIndex < 0 || node.pageIndex >= pageCount)
                node.pageIndex = -1;
        }
        applyOutlineOffset(&node.children, offset, pageCount);
    }
}

static void filterOutlineNodes(std::vector<OutlineNode>* nodes)
{
    if (nodes == nullptr)
        return;

    std::vector<OutlineNode> filtered;
    filtered.reserve(nodes->size());
    for (auto& node : *nodes)
    {
        filterOutlineNodes(&node.children);
        if (node.pageIndex >= 0)
            filtered.push_back(std::move(node));
    }
    *nodes = std::move(filtered);
}

static void collectOutlinePages(std::vector<OutlineNode> const& nodes, std::vector<int>* pages)
{
    if (pages == nullptr)
        return;

    for (auto const& node : nodes)
    {
        if (node.pageIndex < 0 && node.rawPage >= 0)
            pages->push_back(node.rawPage);
        collectOutlinePages(node.children, pages);
    }
}

static int chooseOutlineOffset(std::vector<OutlineNode> const& outline, int pageCount)
{
    std::vector<int> pages;
    collectOutlinePages(outline, &pages);
    if (pages.empty() || pageCount <= 0)
        return 1;

    int minRaw = INT_MAX;
    int maxRaw = -1;
    for (int raw : pages)
    {
        minRaw = MIN(minRaw, raw);
        maxRaw = MAX(maxRaw, raw);
    }

    std::vector<int> candidates;
    candidates.push_back(0);
    candidates.push_back(1);
    for (int d = 0; d <= 3; ++d)
    {
        int c = minRaw - 1 - d;
        if (c >= 0)
            candidates.push_back(c);
    }
    if (maxRaw == pageCount)
        candidates.push_back(1);
    if (maxRaw == pageCount - 1)
        candidates.push_back(0);

    int bestOffset = 1;
    int bestValid = -1;
    int bestDistance = INT_MAX;

    for (int offset : candidates)
    {
        int valid = 0;
        for (int raw : pages)
        {
            int idx = raw - offset;
            if (idx >= 0 && idx < pageCount)
                ++valid;
        }

        int distance = abs(offset - 1);
        if (valid > bestValid || (valid == bestValid && distance < bestDistance))
        {
            bestValid = valid;
            bestOffset = offset;
            bestDistance = distance;
        }
    }

    return bestOffset;
}

static std::vector<OutlineNode> readDjvuOutline(ddjvu_context_t* ctx, ddjvu_document_t* doc, int pageCount)
{
    std::vector<OutlineNode> outline;
    if (ctx == nullptr || doc == nullptr || pageCount <= 0)
        return outline;

    PageTargetMap const pageTargets = buildPageTargetMap(ctx, doc);

    miniexp_t exp = miniexp_dummy;
    while (exp == miniexp_dummy)
    {
        exp = ddjvu_document_get_outline(doc);
        if (exp == miniexp_dummy)
        {
            ddjvu_message_t* msg = ddjvu_message_wait(ctx);
            if (msg)
                ddjvu_message_pop(ctx);
        }
    }

    if (exp == miniexp_nil)
        return outline;

    if (miniexp_symbolp(exp))
    {
        char const* name = miniexp_to_name(exp);
        if (name != nullptr && (strcmp(name, "failed") == 0 || strcmp(name, "stopped") == 0))
        {
            ddjvu_miniexp_release(doc, exp);
            return outline;
        }
    }

    miniexp_t list = exp;
    if (miniexp_consp(list) && miniexp_symbolp(miniexp_car(list)))
    {
        char const* head = miniexp_to_name(miniexp_car(list));
        if (head != nullptr && strcmp(head, "bookmarks") == 0)
            list = miniexp_cdr(list);
    }

    while (miniexp_consp(list))
    {
        miniexp_t entry = miniexp_car(list);
        OutlineNode node;
        if (parseOutlineEntry(doc, pageTargets, entry, &node))
            outline.push_back(std::move(node));
        list = miniexp_cdr(list);
    }

    ddjvu_miniexp_release(doc, exp);

    if (!outline.empty())
    {
        int const offset = chooseOutlineOffset(outline, pageCount);
        applyOutlineOffset(&outline, offset, pageCount);
        filterOutlineNodes(&outline);
    }

    return outline;
}

// Use Otsu adaptive threshold to find content bounds (better than fixed threshold for light content)
static bool findContentRectOtsu(unsigned char const* gray, int w, int h, size_t rowBytes, CropRect* out)
{
    if (gray == nullptr || out == nullptr || w <= 0 || h <= 0)
        return false;

    PIX* pix8 = pixCreate(w, h, 8);
    if (pix8 == nullptr)
        return false;

    for (int y = 0; y < h; ++y)
    {
        auto const* srcRow = gray + (size_t)y * rowBytes;
        l_uint32* dstRow = pixGetData(pix8) + y * pixGetWpl(pix8);
        for (int x = 0; x < w; ++x)
            SET_DATA_BYTE(dstRow, x, srcRow[x]);
    }

    // Invert so content becomes foreground (bright), then Otsu threshold
    pixInvert(pix8, pix8);
    PIX* bin = nullptr;
    pixOtsuAdaptiveThreshold(pix8, 0, 0, 0, 0, 0.0f, nullptr, &bin);
    pixDestroy(&pix8);

    if (bin == nullptr)
        return false;

    BOX* box = nullptr;
    bool found = (pixClipToForeground(bin, nullptr, &box) == 0 && box != nullptr);
    pixDestroy(&bin);

    if (!found)
        return false;

    l_int32 bx, by, bw, bh;
    boxGetGeometry(box, &bx, &by, &bw, &bh);
    boxDestroy(&box);

    out->x0 = bx;
    out->y0 = by;
    out->x1 = bx + bw;
    out->y1 = by + bh;
    return true;
}

static void setPdfPlacementForCrop(DjvuPdfImageInfo* img, int fullW, int fullH, CropRect const& r, double pagePdfW, double pagePdfH)
{
    if (img == nullptr || fullW <= 0 || fullH <= 0)
        return;

    int const w = r.x1 - r.x0;
    int const h = r.y1 - r.y0;
    img->x = (double)r.x0 * pagePdfW / (double)fullW;
    img->y = (double)(fullH - r.y1) * pagePdfH / (double)fullH;
    img->pdfW = (double)w * pagePdfW / (double)fullW;
    img->pdfH = (double)h * pagePdfH / (double)fullH;
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

// Quality levels for JP2 encoding (PSNR in dB)
enum class Jp2Quality
{
    Background, // 40 dB - compound page backgrounds (behind text, can be lower)
    Photo, // 42 dB - smooth photographs
    Document, // 46 dB - document scans, mixed content
    Sharp // 50 dB - near-bitonal, sharp edges
};

static double jp2QualityToPsnr(Jp2Quality q)
{
    switch (q)
    {
    case Jp2Quality::Background:
        return 40.0;
    case Jp2Quality::Photo:
        return 42.0;
    case Jp2Quality::Document:
        return 46.0;
    case Jp2Quality::Sharp:
        return 50.0;
    }
    return 44.0;
}

// Map DjVu page type to JP2 quality
static Jp2Quality pageTypeToQuality(ddjvu_page_type_t pageType)
{
    switch (pageType)
    {
    case DDJVU_PAGETYPE_BITONAL:
        return Jp2Quality::Sharp; // Near-bitonal that didn't go to JBIG2
    case DDJVU_PAGETYPE_PHOTO:
        return Jp2Quality::Photo;
    case DDJVU_PAGETYPE_COMPOUND:
        return Jp2Quality::Document; // Mixed content
    default:
        return Jp2Quality::Document;
    }
}

static bool encodeJp2Grok(std::vector<uint8_t>* out, unsigned char const* pixels, int w, int h, size_t stride, bool gray, Jp2Quality quality = Jp2Quality::Document)
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

    // Copy pixels into Grok's planar int32 component buffers
    for (int y = 0; y < h; ++y)
    {
        auto const* srcRow = pixels + (size_t)y * stride;
        if (gray)
        {
            auto* dstRow = (int32_t*)image->comps[0].data + (uint32_t)y * image->comps[0].stride;
            for (int x = 0; x < w; ++x)
                dstRow[x] = srcRow[x];
        }
        else
        {
            auto* dstR = (int32_t*)image->comps[0].data + (uint32_t)y * image->comps[0].stride;
            auto* dstG = (int32_t*)image->comps[1].data + (uint32_t)y * image->comps[1].stride;
            auto* dstB = (int32_t*)image->comps[2].data + (uint32_t)y * image->comps[2].stride;
            for (int x = 0; x < w; ++x)
            {
                int const offset = x * 3;
                dstR[x] = srcRow[offset];
                dstG[x] = srcRow[offset + 1];
                dstB[x] = srcRow[offset + 2];
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
    params.irreversible = true;
    params.numlayers = 1;
    params.num_threads = 2;
    params.allocation_by_quality = true;
    params.layer_distortion[0] = jp2QualityToPsnr(quality);

    size_t rawSize = stride * (size_t)h;
    size_t cap = MAX(rawSize + 1024U * 1024U, (size_t)64 * 1024);

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

        cap *= 2;
    }

    if (codec != nullptr)
        grk_object_unref(codec);
    grk_object_unref(&image->obj);

    return ok;
}

struct Jbig2Batch
{
    std::vector<PIX*> pixes;
    std::vector<int> pageNums;
};

// Async JBIG2 encoding context
struct Jbig2AsyncContext
{
    dispatch_group_t group;
    dispatch_queue_t queue;
    std::mutex mutex; // Protects pages and globals
    std::vector<DjvuPdfPageInfo>* pages;
    std::vector<std::vector<uint8_t>>* globals;
    std::atomic<bool> ok{ true };
    NSString* djvuPath;
};

static void flushJbig2BatchAsync(Jbig2Batch batch, Jbig2AsyncContext* ctx)
{
    if (batch.pixes.empty() || ctx == nullptr)
    {
        for (auto*& pix : batch.pixes)
            pixDestroy(&pix);
        return;
    }

    dispatch_group_async(ctx->group, ctx->queue, ^{
        jbig2ctx* jb2 = jbig2_init(0.85f, 0.5f, 0, 0, false, -1);
        if (jb2 == nullptr)
        {
            NSLog(@"DjvuConverter ERROR: jbig2_init failed for %@", ctx->djvuPath);
            for (auto* pix : batch.pixes)
                pixDestroy(&pix);
            ctx->ok = false;
            return;
        }

        for (auto* pix : batch.pixes)
            jbig2_add_page(jb2, pix);

        int globalsLen = 0;
        uint8_t* globalsBuf = jbig2_pages_complete(jb2, &globalsLen);
        if (globalsBuf == nullptr || globalsLen <= 0)
        {
            NSLog(@"DjvuConverter ERROR: jbig2_pages_complete failed for %@", ctx->djvuPath);
            jbig2_destroy(jb2);
            for (auto* pix : batch.pixes)
                pixDestroy(&pix);
            ctx->ok = false;
            return;
        }

        // Lock for writing to shared globals and pages
        std::lock_guard<std::mutex> lock(ctx->mutex);

        size_t globalsIndex = ctx->globals->size();
        ctx->globals->emplace_back(globalsBuf, globalsBuf + (size_t)globalsLen);
        free(globalsBuf);

        for (size_t i = 0; i < batch.pageNums.size(); ++i)
        {
            int len = 0;
            uint8_t* pageBuf = jbig2_produce_page(jb2, (int)i, -1, -1, &len);
            if (pageBuf == nullptr || len <= 0)
            {
                NSLog(@"DjvuConverter ERROR: jbig2_produce_page failed for batch index %zu in %@", i, ctx->djvuPath);
                ctx->ok = false;
                break;
            }

            int const rawPageNum = batch.pageNums[i];
            bool const isFgMask = (rawPageNum < 0);
            int const pageIndex = isFgMask ? (-1 - rawPageNum) : rawPageNum;
            DjvuPdfPageInfo& pageInfo = (*ctx->pages)[(size_t)pageIndex];

            if (isFgMask)
            {
                pageInfo.fgMask.bytes.assign(pageBuf, pageBuf + (size_t)len);
                pageInfo.fgMask.jbig2GlobalsIndex = (int)globalsIndex;
            }
            else
            {
                pageInfo.image.bytes.assign(pageBuf, pageBuf + (size_t)len);
                pageInfo.image.jbig2GlobalsIndex = (int)globalsIndex;
            }
            free(pageBuf);
        }

        jbig2_destroy(jb2);
        for (auto* pix : batch.pixes)
            pixDestroy(&pix);
    });
}

struct PdfOutlineItem
{
    std::string title;
    int pageIndex = -1;
    int parent = -1;
    int firstChild = -1;
    int lastChild = -1;
    int prev = -1;
    int next = -1;
    int count = 0;
};

struct OutlineBuildResult
{
    int first = -1;
    int last = -1;
    int descendants = 0;
};

static OutlineBuildResult buildOutlineItems(std::vector<PdfOutlineItem>* items, std::vector<OutlineNode> const& nodes, int parent)
{
    OutlineBuildResult result;
    int prev = -1;

    for (auto const& node : nodes)
    {
        int const idx = (int)items->size();
        items->push_back({ node.title, node.pageIndex, parent });

        if (result.first == -1)
            result.first = idx;
        if (prev != -1)
        {
            (*items)[prev].next = idx;
            (*items)[idx].prev = prev;
        }
        prev = idx;

        OutlineBuildResult childResult;
        if (!node.children.empty())
        {
            childResult = buildOutlineItems(items, node.children, idx);
            (*items)[idx].firstChild = childResult.first;
            (*items)[idx].lastChild = childResult.last;
            (*items)[idx].count = childResult.descendants;
        }

        result.last = idx;
        result.descendants += 1 + (*items)[idx].count;
    }

    return result;
}

static std::string pdfEscapeString(std::string_view text)
{
    std::string out;
    out.reserve(text.size() + 8);
    for (unsigned char ch : text)
    {
        switch (ch)
        {
        case '\\':
        case '(':
        case ')':
            out.push_back('\\');
            out.push_back((char)ch);
            break;
        case '\n':
            out.append("\\n");
            break;
        case '\r':
            out.append("\\r");
            break;
        case '\t':
            out.append("\\t");
            break;
        default:
            out.push_back((char)ch);
            break;
        }
    }
    return out;
}

static void appendHexByte(std::string* out, unsigned char value)
{
    static char constexpr Hex[] = "0123456789ABCDEF";
    out->push_back(Hex[value >> 4]);
    out->push_back(Hex[value & 0x0F]);
}

static std::string pdfOutlineTitle(std::string_view text)
{
    NSString* ns = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    if (ns == nil)
        return "(" + pdfEscapeString(text) + ")";

    NSData* data = [ns dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    if (data == nil)
        return "(" + pdfEscapeString(text) + ")";

    std::string out;
    out.reserve(2 + (data.length + 2) * 2);
    out.push_back('<');
    out.append("FEFF");
    unsigned char const* bytes = static_cast<unsigned char const*>(data.bytes);
    for (NSUInteger i = 0; i < data.length; ++i)
        appendHexByte(&out, bytes[i]);
    out.push_back('>');
    return out;
}

static bool writePdfDeterministic(
    NSString* tmpPdfPath,
    std::vector<DjvuPdfPageInfo> const& pages,
    std::vector<std::vector<uint8_t>> const& jbig2Globals,
    std::vector<OutlineNode> const& outlineNodes)
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
        int img = 0; // Single image (non-compound) or unused for compound
        int bgImg = 0; // Background image for compound pages
        int fgMask = 0; // Foreground mask for compound pages
        int contents = 0;
        int page = 0;
    };

    std::vector<PageObjs> pageObjs(pages.size());

    int nextObj = 1;
    int const catalogObj = nextObj++;
    int const pagesObj = nextObj++;
    std::vector<int> jbig2GlobalsObjs(jbig2Globals.size(), 0);
    for (size_t i = 0; i < jbig2Globals.size(); ++i)
    {
        if (!jbig2Globals[i].empty())
            jbig2GlobalsObjs[i] = nextObj++;
    }

    std::vector<PdfOutlineItem> outlineItems;
    std::vector<int> outlineObjs;
    int outlinesObj = 0;
    OutlineBuildResult outlineResult;
    if (!outlineNodes.empty())
    {
        outlineResult = buildOutlineItems(&outlineItems, outlineNodes, -1);
        if (!outlineItems.empty())
        {
            outlinesObj = nextObj++;
            outlineObjs.resize(outlineItems.size(), 0);
            for (size_t i = 0; i < outlineItems.size(); ++i)
                outlineObjs[i] = nextObj++;
        }
    }

    for (size_t i = 0; i < pages.size(); ++i)
    {
        bool const isCompound =
            (pages[i].bgImage.kind != DjvuPdfImageKind::None && !pages[i].bgImage.bytes.empty() &&
             pages[i].fgMask.kind != DjvuPdfImageKind::None && !pages[i].fgMask.bytes.empty());
        if (isCompound)
        {
            pageObjs[i].bgImg = nextObj++;
            pageObjs[i].fgMask = nextObj++;
        }
        else if (pages[i].image.kind != DjvuPdfImageKind::None && !pages[i].image.bytes.empty())
        {
            pageObjs[i].img = nextObj++;
        }
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
    if (outlinesObj != 0)
        fprintf(fp, "<< /Type /Catalog /Pages %d 0 R /Outlines %d 0 R /PageMode /UseOutlines >>\n", pagesObj, outlinesObj);
    else
        fprintf(fp, "<< /Type /Catalog /Pages %d 0 R >>\n", pagesObj);
    writeObjEnd();

    // 2) Pages tree
    writeObjBegin(pagesObj);
    fputs("<< /Type /Pages /Kids [", fp);
    for (size_t i = 0; i < pages.size(); ++i)
        fprintf(fp, " %d 0 R", pageObjs[i].page);
    fprintf(fp, " ] /Count %zu >>\n", pages.size());
    writeObjEnd();

    // 3) Outlines
    if (outlinesObj != 0)
    {
        writeObjBegin(outlinesObj);
        if (outlineResult.first != -1)
        {
            fprintf(
                fp,
                "<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>\n",
                outlineObjs[(size_t)outlineResult.first],
                outlineObjs[(size_t)outlineResult.last],
                outlineResult.descendants);
        }
        else
        {
            fputs("<< /Type /Outlines >>\n", fp);
        }
        writeObjEnd();

        for (size_t i = 0; i < outlineItems.size(); ++i)
        {
            auto const& item = outlineItems[i];
            int const parentObj = item.parent == -1 ? outlinesObj : outlineObjs[(size_t)item.parent];
            int pageIndex = item.pageIndex;
            if (pageIndex < 0 || (size_t)pageIndex >= pageObjs.size())
                pageIndex = 0;

            std::string const titleToken = pdfOutlineTitle(item.title);

            writeObjBegin(outlineObjs[i]);
            fprintf(
                fp,
                "<< /Title %s /Parent %d 0 R /Dest [%d 0 R /Fit]",
                titleToken.c_str(),
                parentObj,
                pageObjs[(size_t)pageIndex].page);
            if (item.prev != -1)
                fprintf(fp, " /Prev %d 0 R", outlineObjs[(size_t)item.prev]);
            if (item.next != -1)
                fprintf(fp, " /Next %d 0 R", outlineObjs[(size_t)item.next]);
            if (item.firstChild != -1)
            {
                fprintf(
                    fp,
                    " /First %d 0 R /Last %d 0 R /Count %d",
                    outlineObjs[(size_t)item.firstChild],
                    outlineObjs[(size_t)item.lastChild],
                    item.count);
            }
            fputs(" >>\n", fp);
            writeObjEnd();
        }
    }

    // 4) JBIG2Globals
    for (size_t i = 0; i < jbig2Globals.size(); ++i)
    {
        int obj = jbig2GlobalsObjs[i];
        if (obj != 0)
            writeStreamObj(obj, "<< ", jbig2Globals[i].data(), jbig2Globals[i].size());
    }

    // 5) Per-page objects
    for (size_t i = 0; i < pages.size(); ++i)
    {
        DjvuPdfPageInfo const& p = pages[i];
        PageObjs const& o = pageObjs[i];
        bool const isCompound = (o.bgImg != 0 && o.fgMask != 0);

        if (isCompound)
        {
            // Write background image (JP2)
            DjvuPdfImageInfo const& bgImg = p.bgImage;
            writeObjBegin(o.bgImg);
            char const* bgCs = bgImg.gray ? "/DeviceGray" : "/DeviceRGB";
            fprintf(
                fp,
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8 /Filter /JPXDecode /Length %zu >>\nstream\n",
                bgImg.w,
                bgImg.h,
                bgCs,
                bgImg.bytes.size());
            fwrite(bgImg.bytes.data(), 1, bgImg.bytes.size(), fp);
            fputs("\nendstream\n", fp);
            writeObjEnd();

            // Write foreground mask (JBIG2 ImageMask)
            DjvuPdfImageInfo const& fgMask = p.fgMask;
            if (fgMask.jbig2GlobalsIndex < 0 || (size_t)fgMask.jbig2GlobalsIndex >= jbig2GlobalsObjs.size())
                return false;
            int const fgGlobalsObj = jbig2GlobalsObjs[(size_t)fgMask.jbig2GlobalsIndex];
            if (fgGlobalsObj == 0)
                return false;
            writeObjBegin(o.fgMask);
            // ImageMask: sample 1 paints with fill color, sample 0 is transparent (default Decode [0 1])
            // JBIG2: 1 = black text, 0 = white background
            // Result: black text paints, white background is transparent
            fprintf(
                fp,
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms << /JBIG2Globals %d 0 R >> /Length %zu >>\nstream\n",
                fgMask.w,
                fgMask.h,
                fgGlobalsObj,
                fgMask.bytes.size());
            fwrite(fgMask.bytes.data(), 1, fgMask.bytes.size(), fp);
            fputs("\nendstream\n", fp);
            writeObjEnd();
        }
        else if (o.img != 0)
        {
            DjvuPdfImageInfo const& img = p.image;
            writeObjBegin(o.img);
            if (img.kind == DjvuPdfImageKind::Jp2)
            {
                char const* cs = img.gray ? "/DeviceGray" : "/DeviceRGB";
                fprintf(
                    fp,
                    "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8 /Filter /JPXDecode /Length %zu >>\nstream\n",
                    img.w,
                    img.h,
                    cs,
                    img.bytes.size());
            }
            else if (img.kind == DjvuPdfImageKind::Jbig2)
            {
                if (img.jbig2GlobalsIndex < 0 || (size_t)img.jbig2GlobalsIndex >= jbig2GlobalsObjs.size())
                    return false;
                int const globalsObj = jbig2GlobalsObjs[(size_t)img.jbig2GlobalsIndex];
                if (globalsObj == 0)
                    return false;
                fprintf(
                    fp,
                    "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms << /JBIG2Globals %d 0 R >> /Length %zu >>\nstream\n",
                    img.w,
                    img.h,
                    globalsObj,
                    img.bytes.size());
            }
            else
            {
                writeObjEnd();
                return false;
            }

            fwrite(img.bytes.data(), 1, img.bytes.size(), fp);
            fputs("\nendstream\n", fp);
            writeObjEnd();
        }

        // Contents stream
        std::string contents;
        contents.reserve(256);
        if (isCompound)
        {
            DjvuPdfImageInfo const& bgImg = p.bgImage;
            DjvuPdfImageInfo const& fgMask = p.fgMask;
            char tmp[256];
            // Draw background picture first
            snprintf(tmp, sizeof(tmp), "q\n%g 0 0 %g %g %g cm\n/BgIm Do\nQ\n", bgImg.pdfW, bgImg.pdfH, bgImg.x, bgImg.y);
            contents.append(tmp);
            // Draw foreground text mask on top (black fill color for text)
            snprintf(tmp, sizeof(tmp), "q\n0 g\n%g 0 0 %g %g %g cm\n/FgMask Do\nQ\n", fgMask.pdfW, fgMask.pdfH, fgMask.x, fgMask.y);
            contents.append(tmp);
        }
        else if (o.img != 0)
        {
            DjvuPdfImageInfo const& img = p.image;
            char tmp[256];
            snprintf(tmp, sizeof(tmp), "q\n%g 0 0 %g %g %g cm\n/Im Do\nQ\n", img.pdfW, img.pdfH, img.x, img.y);
            contents.append(tmp);
        }

        writeStreamObj(o.contents, "<< ", (uint8_t const*)contents.data(), contents.size());

        // Page dictionary
        writeObjBegin(o.page);
        fprintf(fp, "<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %g %g] ", pagesObj, p.pdfWidth, p.pdfHeight);
        fputs("/Resources << ", fp);
        if (isCompound)
        {
            fputs("/XObject << ", fp);
            fprintf(fp, "/BgIm %d 0 R /FgMask %d 0 R ", o.bgImg, o.fgMask);
            fputs(">> ", fp);
        }
        else if (o.img != 0)
        {
            fputs("/XObject << ", fp);
            fprintf(fp, "/Im %d 0 R ", o.img);
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
    {
        NSLog(@"DjvuConverter ERROR: failed to create DJVU context for %@", djvuPath);
        return NO;
    }

    ddjvu_document_t* doc = ddjvu_document_create_by_filename_utf8(ctx, djvuPath.UTF8String, TRUE);
    if (!doc)
    {
        NSLog(@"DjvuConverter ERROR: failed to open DJVU document: %@", djvuPath);
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
        NSLog(@"DjvuConverter ERROR: DJVU document decoding failed: %@", djvuPath);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    int pageCount = ddjvu_document_get_pagenum(doc);
    if (pageCount <= 0)
    {
        NSLog(@"DjvuConverter ERROR: invalid page count (%d) for %@", pageCount, djvuPath);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    setTotalPagesForPath(djvuPath, pageCount);

    std::vector<OutlineNode> outline = readDjvuOutline(ctx, doc, pageCount);

    std::vector<DjvuPdfPageInfo> pages((size_t)pageCount);
    DjvuPdfPageInfo* pagesPtr = pages.data();

    ddjvu_format_t* rgb24 = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, nullptr);
    ddjvu_format_t* grey8 = ddjvu_format_create(DDJVU_FORMAT_GREY8, 0, nullptr);
    ddjvu_format_t* msb = ddjvu_format_create(DDJVU_FORMAT_MSBTOLSB, 0, nullptr);
    if (!rgb24 || !grey8 || !msb)
    {
        NSLog(@"DjvuConverter ERROR: failed to create pixel format for %@", djvuPath);
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

    dispatch_queue_t encQ = dispatch_queue_create("transmission.djvu.jp2.encode", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t encGroup = dispatch_group_create();

    // Allow concurrent JP2 encodes. Each encode uses 2 threads (see encodeJp2Grok),
    // so limit concurrency to cpu/2 for optimal thread utilization.
    NSInteger cpu = NSProcessInfo.processInfo.activeProcessorCount;
    NSInteger maxJp2Concurrent = MAX(2, cpu / 2);
    dispatch_semaphore_t sem = dispatch_semaphore_create(maxJp2Concurrent);

    bool ok = true;
    // Smaller batches = more parallelism, larger = better symbol sharing
    int const Jbig2BatchSize = MAX(8, MIN(20, pageCount / (int)cpu));
    Jbig2Batch jbig2Batch;
    std::vector<std::vector<uint8_t>> jbig2Globals;

    // Async JBIG2 context - allows overlapping JBIG2 encoding with page rendering
    Jbig2AsyncContext jbig2Ctx;
    jbig2Ctx.group = dispatch_group_create();
    jbig2Ctx.queue = dispatch_queue_create("transmission.djvu.jbig2.encode", DISPATCH_QUEUE_CONCURRENT);
    jbig2Ctx.pages = &pages;
    jbig2Ctx.globals = &jbig2Globals;
    jbig2Ctx.djvuPath = djvuPath;

    for (int pageNum = 0; pageNum < pageCount && ok; ++pageNum)
    {
        @autoreleasepool
        {
            ddjvu_page_t* page = ddjvu_page_create_by_pageno(doc, pageNum);
            if (!page)
            {
                NSLog(@"DjvuConverter ERROR: failed to create page %d in %@", pageNum, djvuPath);
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
                NSLog(@"DjvuConverter ERROR: page %d decoding failed in %@", pageNum, djvuPath);
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
                NSLog(@"DjvuConverter ERROR: invalid page dimensions (w=%d h=%d dpi=%d) for page %d in %@", pageWidth, pageHeight, pageDpi, pageNum, djvuPath);
                ddjvu_page_release(page);
                ok = false;
                break;
            }

            DjvuPdfPageInfo& p = pagesPtr[pageNum];
            p.pdfWidth = (double)pageWidth * 72.0 / (double)pageDpi;
            p.pdfHeight = (double)pageHeight * 72.0 / (double)pageDpi;

            int constexpr MaxRenderDpi = 300;
            int renderDpi = MIN(MaxRenderDpi, pageDpi);
            int renderW = 0;
            int renderH = 0;
            computeRenderDimensions(pageWidth, pageHeight, pageDpi, renderDpi, &renderW, &renderH);
            if (renderW <= 0 || renderH <= 0)
            {
                ddjvu_page_release(page);
                ok = false;
                break;
            }

            // Handle compound pages (text over picture) specially
            if (pageType == DDJVU_PAGETYPE_COMPOUND)
            {
                // Render foreground text mask FIRST to check if compound mode is worthwhile
                double maskCoverage = 0.0;
                bool const preferBitonal = (renderDpi == pageDpi) && (renderW == pageWidth) && (renderH == pageHeight);
                NSData* fgPbm = renderDjvuMaskPbmData(page, grey8, msb, renderW, renderH, preferBitonal, &maskCoverage);
                PIX* fgPix = (fgPbm != nil && fgPbm.length != 0) ? pixReadMemPnm((l_uint8 const*)fgPbm.bytes, fgPbm.length) : nullptr;

                // Only proceed with compound rendering if we have meaningful text coverage
                if (fgPix != nullptr && maskCoverage > 0.001)
                {
                    // Render background at lower DPI (DjVu backgrounds are typically 100 DPI)
                    int constexpr MaxBgDpi = 150;
                    int bgDpi = MIN(MaxBgDpi, pageDpi);
                    int bgW = 0;
                    int bgH = 0;
                    computeRenderDimensions(pageWidth, pageHeight, pageDpi, bgDpi, &bgW, &bgH);

                    size_t bgRowBytes = (size_t)bgW * 3U;
                    std::vector<uint8_t> bgRgb(bgRowBytes * (size_t)bgH, (uint8_t)0xFF);
                    ddjvu_rect_t bgRect = { 0, 0, (unsigned int)bgW, (unsigned int)bgH };
                    int bgRendered = ddjvu_page_render(
                        page,
                        DDJVU_RENDER_BACKGROUND,
                        &bgRect,
                        &bgRect,
                        rgb24,
                        (unsigned long)bgRowBytes,
                        (char*)bgRgb.data());

                    if (bgRendered)
                    {
                        // Process background: determine if grayscale or RGB
                        bool const bgGray = isGrayscaleRgb24(bgRgb.data(), bgW, bgH, bgRowBytes);
                        int constexpr CropPad = 4;

                        // Crop each layer independently to its own content bounds
                        int fgFullW = pixGetWidth(fgPix);
                        int fgFullH = pixGetHeight(fgPix);

                        // Find foreground text bounds
                        CropRect fgCrop = { 0, 0, fgFullW, fgFullH };
                        BOX* fgBox = nullptr;
                        if (pixClipToForeground(fgPix, nullptr, &fgBox) == 0 && fgBox != nullptr)
                        {
                            l_int32 bx, by, bw, bh;
                            boxGetGeometry(fgBox, &bx, &by, &bw, &bh);
                            fgCrop = { MAX(0, bx - CropPad), MAX(0, by - CropPad), MIN(fgFullW, bx + bw + CropPad), MIN(fgFullH, by + bh + CropPad) };
                            boxDestroy(&fgBox);
                        }

                        // Use Leptonica's adaptive thresholding to find background content bounds
                        CropRect bgCrop = { 0, 0, bgW, bgH };
                        PIX* bgPix8 = nullptr;
                        if (bgGray)
                        {
                            // Create grayscale PIX from buffer
                            bgPix8 = pixCreate(bgW, bgH, 8);
                            if (bgPix8 != nullptr)
                            {
                                for (int y = 0; y < bgH; ++y)
                                {
                                    auto const* srcRow = bgRgb.data() + (size_t)y * bgRowBytes;
                                    l_uint32* dstRow = pixGetData(bgPix8) + y * pixGetWpl(bgPix8);
                                    for (int x = 0; x < bgW; ++x)
                                        SET_DATA_BYTE(dstRow, x, srcRow[x * 3]);
                                }
                            }
                        }
                        else
                        {
                            // Convert RGB to grayscale for content detection using helper
                            std::vector<unsigned char> grayBuf = rgb24ToGrayscale(bgRgb.data(), bgW, bgH, bgRowBytes);
                            bgPix8 = pixCreate(bgW, bgH, 8);
                            if (bgPix8 != nullptr)
                            {
                                for (int y = 0; y < bgH; ++y)
                                {
                                    auto const* srcRow = grayBuf.data() + (size_t)y * (size_t)bgW;
                                    l_uint32* dstRow = pixGetData(bgPix8) + y * pixGetWpl(bgPix8);
                                    for (int x = 0; x < bgW; ++x)
                                        SET_DATA_BYTE(dstRow, x, srcRow[x]);
                                }
                            }
                        }

                        if (bgPix8 != nullptr)
                        {
                            // Invert so content becomes foreground (white), then use Otsu threshold
                            pixInvert(bgPix8, bgPix8);
                            PIX* bgBin = nullptr;
                            pixOtsuAdaptiveThreshold(bgPix8, 0, 0, 0, 0, 0.0f, nullptr, &bgBin);
                            if (bgBin != nullptr)
                            {
                                BOX* bgBox = nullptr;
                                if (pixClipToForeground(bgBin, nullptr, &bgBox) == 0 && bgBox != nullptr)
                                {
                                    l_int32 bx, by, bw, bh;
                                    boxGetGeometry(bgBox, &bx, &by, &bw, &bh);
                                    bgCrop = { MAX(0, bx - CropPad), MAX(0, by - CropPad), MIN(bgW, bx + bw + CropPad), MIN(bgH, by + bh + CropPad) };
                                    boxDestroy(&bgBox);
                                }
                                pixDestroy(&bgBin);
                            }
                            pixDestroy(&bgPix8);
                        }

                        int fgCropW = fgCrop.x1 - fgCrop.x0;
                        int fgCropH = fgCrop.y1 - fgCrop.y0;
                        int bgCropW = bgCrop.x1 - bgCrop.x0;
                        int bgCropH = bgCrop.y1 - bgCrop.y0;

                        if (fgCropW <= 0 || fgCropH <= 0 || bgCropW <= 0 || bgCropH <= 0)
                        {
                            pixDestroy(&fgPix);
                            // Fall through to normal rendering
                        }
                        else
                        {
                            // PDF placement for background (from its own crop bounds)
                            double bgPdfX = (double)bgCrop.x0 / (double)bgW * p.pdfWidth;
                            double bgPdfY = (1.0 - (double)bgCrop.y1 / (double)bgH) * p.pdfHeight;
                            double bgPdfW = (double)bgCropW / (double)bgW * p.pdfWidth;
                            double bgPdfH = (double)bgCropH / (double)bgH * p.pdfHeight;

                            // PDF placement for foreground (from its own crop bounds)
                            double fgPdfX = (double)fgCrop.x0 / (double)fgFullW * p.pdfWidth;
                            double fgPdfY = (1.0 - (double)fgCrop.y1 / (double)fgFullH) * p.pdfHeight;
                            double fgPdfW = (double)fgCropW / (double)fgFullW * p.pdfWidth;
                            double fgPdfH = (double)fgCropH / (double)fgFullH * p.pdfHeight;

                            // Set up background image info
                            p.bgImage.kind = DjvuPdfImageKind::Jp2;
                            p.bgImage.gray = bgGray;
                            p.bgImage.w = bgCropW;
                            p.bgImage.h = bgCropH;
                            p.bgImage.x = bgPdfX;
                            p.bgImage.y = bgPdfY;
                            p.bgImage.pdfW = bgPdfW;
                            p.bgImage.pdfH = bgPdfH;

                            // Encode cropped background as JP2
                            if (bgGray)
                            {
                                std::vector<unsigned char> grayBuf = rgb24ToGrayscale(bgRgb.data(), bgW, bgH, bgRowBytes);
                                std::vector<unsigned char> croppedGray = extractGrayCrop(grayBuf.data(), bgW, bgCrop);
                                dispatch_group_async(encGroup, encQ, ^{
                                    @autoreleasepool
                                    {
                                        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                                        std::vector<uint8_t> jp2;
                                        (void)encodeJp2Grok(&jp2, croppedGray.data(), bgCropW, bgCropH, (size_t)bgCropW, true, Jp2Quality::Background);
                                        if (!jp2.empty())
                                            pagesPtr[pageNum].bgImage.bytes = std::move(jp2);
                                        dispatch_semaphore_signal(sem);
                                    }
                                });
                            }
                            else
                            {
                                std::vector<uint8_t> croppedBg = extractRgbCrop(bgRgb.data(), bgRowBytes, bgCrop);
                                dispatch_group_async(encGroup, encQ, ^{
                                    @autoreleasepool
                                    {
                                        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                                        std::vector<uint8_t> jp2;
                                        (void)encodeJp2Grok(&jp2, croppedBg.data(), bgCropW, bgCropH, (size_t)bgCropW * 3U, false, Jp2Quality::Background);
                                        if (!jp2.empty())
                                            pagesPtr[pageNum].bgImage.bytes = std::move(jp2);
                                        dispatch_semaphore_signal(sem);
                                    }
                                });
                            }

                            // Crop foreground mask
                            BOX* fgClipBox = boxCreate(fgCrop.x0, fgCrop.y0, fgCropW, fgCropH);
                            PIX* fgCropped = fgClipBox != nullptr ? pixClipRectangle(fgPix, fgClipBox, nullptr) : nullptr;
                            boxDestroy(&fgClipBox);
                            pixDestroy(&fgPix);

                            if (fgCropped == nullptr || pixGetWidth(fgCropped) <= 0 || pixGetHeight(fgCropped) <= 0)
                            {
                                if (fgCropped != nullptr)
                                    pixDestroy(&fgCropped);
                                // Fall through to normal rendering
                            }
                            else
                            {
                                // Set up foreground mask info
                                p.fgMask.kind = DjvuPdfImageKind::Jbig2;
                                p.fgMask.w = pixGetWidth(fgCropped);
                                p.fgMask.h = pixGetHeight(fgCropped);
                                p.fgMask.x = fgPdfX;
                                p.fgMask.y = fgPdfY;
                                p.fgMask.pdfW = fgPdfW;
                                p.fgMask.pdfH = fgPdfH;

                                // Add foreground mask to JBIG2 batch
                                jbig2Batch.pageNums.push_back(-1 - pageNum); // Negative to indicate it's a foreground mask
                                jbig2Batch.pixes.push_back(fgCropped);

                                if ((int)jbig2Batch.pixes.size() >= Jbig2BatchSize)
                                {
                                    flushJbig2BatchAsync(std::move(jbig2Batch), &jbig2Ctx);
                                    jbig2Batch = Jbig2Batch{};
                                }

                                ddjvu_page_release(page);
                                incrementDonePagesForPath(djvuPath);
                                continue; // Skip normal rendering path
                            }
                        }
                    }
                }

                if (fgPix != nullptr)
                    pixDestroy(&fgPix);
                // Fall through to normal rendering if compound rendering didn't work
            }

            size_t rowBytes = (size_t)renderW * 3U;
            std::vector<uint8_t> rgb(rowBytes * (size_t)renderH, (uint8_t)0xFF);
            ddjvu_rect_t rect = { 0, 0, (unsigned int)renderW, (unsigned int)renderH };

            std::vector<ddjvu_render_mode_t> modesToTry = { DDJVU_RENDER_COLOR };
            if (pageType == DDJVU_PAGETYPE_UNKNOWN)
            {
                modesToTry = { DDJVU_RENDER_COLOR, DDJVU_RENDER_BLACK, DDJVU_RENDER_COLORONLY, DDJVU_RENDER_FOREGROUND, DDJVU_RENDER_BACKGROUND };
            }

            int rendered = 0;
            for (auto mode : modesToTry)
            {
                std::fill(rgb.begin(), rgb.end(), (uint8_t)0xFF);
                rendered = ddjvu_page_render(page, mode, &rect, &rect, rgb24, (unsigned long)rowBytes, (char*)rgb.data());
                if (rendered)
                    break;
            }

            // If scaled render failed, try native resolution and scale down.
            if (!rendered && (renderW != pageWidth || renderH != pageHeight))
            {
                size_t nativeRowBytes = (size_t)pageWidth * 3U;
                std::vector<uint8_t> nativeRgb(nativeRowBytes * (size_t)pageHeight, (uint8_t)0xFF);
                ddjvu_rect_t nativeRect = { 0, 0, (unsigned int)pageWidth, (unsigned int)pageHeight };

                for (auto mode : modesToTry)
                {
                    std::fill(nativeRgb.begin(), nativeRgb.end(), (uint8_t)0xFF);
                    rendered = ddjvu_page_render(
                        page,
                        mode,
                        &nativeRect,
                        &nativeRect,
                        rgb24,
                        (unsigned long)nativeRowBytes,
                        (char*)nativeRgb.data());
                    if (rendered)
                        break;
                }

                if (rendered)
                {
                    double scaleX = (double)pageWidth / (double)renderW;
                    double scaleY = (double)pageHeight / (double)renderH;
                    for (int y = 0; y < renderH; ++y)
                    {
                        int srcY = MIN((int)(y * scaleY), pageHeight - 1);
                        auto const* srcRow = nativeRgb.data() + (size_t)srcY * nativeRowBytes;
                        auto* dstRow = rgb.data() + (size_t)y * rowBytes;
                        for (int x = 0; x < renderW; ++x)
                        {
                            int srcX = MIN((int)(x * scaleX), pageWidth - 1);
                            auto const* src = srcRow + (size_t)srcX * 3U;
                            auto* dst = dstRow + (size_t)x * 3U;
                            dst[0] = src[0];
                            dst[1] = src[1];
                            dst[2] = src[2];
                        }
                    }
                }
            }

            if (rendered)
            {
                bool const gray = isGrayscaleRgb24(rgb.data(), renderW, renderH, rowBytes);
                int constexpr CropPad = 4;

                if (gray)
                {
                    // Check bitonal directly from RGB buffer (avoids gray buffer allocation for bitonal pages)
                    // Skip bitonal check for PHOTO pages - they should stay as JP2
                    bool const bitonal = (pageType != DDJVU_PAGETYPE_PHOTO) &&
                        isBitonalGrayscaleRgb(rgb.data(), renderW, renderH, rowBytes);
                    if (bitonal)
                    {
                        bool const preferBitonal = (renderDpi == pageDpi) && (renderW == pageWidth) && (renderH == pageHeight);
                        NSData* pbm = renderDjvuMaskPbmData(page, grey8, msb, renderW, renderH, preferBitonal, nullptr);
                        PIX* pix = (pbm != nil && pbm.length != 0) ? pixReadMemPnm((l_uint8 const*)pbm.bytes, pbm.length) : nullptr;
                        if (pix != nullptr)
                        {
                            BOX* box = nullptr;
                            if (pixClipToForeground(pix, nullptr, &box) == 0 && box != nullptr)
                            {
                                l_int32 bx = 0;
                                l_int32 by = 0;
                                l_int32 bw = 0;
                                l_int32 bh = 0;
                                boxGetGeometry(box, &bx, &by, &bw, &bh);

                                int x0 = MAX(0, (int)bx - CropPad);
                                int y0 = MAX(0, (int)by - CropPad);
                                int x1 = MIN(renderW, (int)bx + (int)bw + CropPad);
                                int y1 = MIN(renderH, (int)by + (int)bh + CropPad);
                                CropRect const cr{ x0, y0, x1, y1 };

                                BOX* clipBox = boxCreate(x0, y0, x1 - x0, y1 - y0);
                                PIX* pixCropped = clipBox != nullptr ? pixClipRectangle(pix, clipBox, nullptr) : nullptr;
                                boxDestroy(&clipBox);
                                boxDestroy(&box);
                                pixDestroy(&pix);

                                if (pixCropped != nullptr && pixGetWidth(pixCropped) > 0 && pixGetHeight(pixCropped) > 0)
                                {
                                    p.image.kind = DjvuPdfImageKind::Jbig2;
                                    p.image.w = pixGetWidth(pixCropped);
                                    p.image.h = pixGetHeight(pixCropped);
                                    setPdfPlacementForCrop(&p.image, renderW, renderH, cr, p.pdfWidth, p.pdfHeight);
                                    jbig2Batch.pageNums.push_back(pageNum);
                                    jbig2Batch.pixes.push_back(pixCropped);
                                    if ((int)jbig2Batch.pixes.size() >= Jbig2BatchSize)
                                    {
                                        flushJbig2BatchAsync(std::move(jbig2Batch), &jbig2Ctx);
                                        jbig2Batch = Jbig2Batch{};
                                    }
                                }
                                else if (pixCropped != nullptr)
                                {
                                    pixDestroy(&pixCropped);
                                }
                            }
                            else
                            {
                                if (box != nullptr)
                                    boxDestroy(&box);
                                pixDestroy(&pix);
                            }
                        }
                    }

                    if (p.image.kind == DjvuPdfImageKind::None)
                    {
                        std::vector<unsigned char> grayBuf = rgb24ToGrayscale(rgb.data(), renderW, renderH, rowBytes);

                        // Try Otsu cropping, fallback to full page if it fails
                        CropRect cr = { 0, 0, renderW, renderH };
                        CropRect otsuCrop{};
                        if (findContentRectOtsu(grayBuf.data(), renderW, renderH, (size_t)renderW, &otsuCrop))
                        {
                            padCropRect(&otsuCrop, CropPad, renderW, renderH);
                            if (otsuCrop.x1 - otsuCrop.x0 > 0 && otsuCrop.y1 - otsuCrop.y0 > 0)
                                cr = otsuCrop;
                        }

                        int cropW = cr.x1 - cr.x0;
                        int cropH = cr.y1 - cr.y0;
                        std::vector<uint8_t> pixels = extractGrayCrop(grayBuf.data(), renderW, cr);

                        p.image.kind = DjvuPdfImageKind::Jp2;
                        p.image.gray = true;
                        p.image.w = cropW;
                        p.image.h = cropH;
                        setPdfPlacementForCrop(&p.image, renderW, renderH, cr, p.pdfWidth, p.pdfHeight);

                        // Use DjVu page type for quality selection
                        Jp2Quality quality = pageTypeToQuality(pageType);

                        dispatch_group_async(encGroup, encQ, ^{
                            @autoreleasepool
                            {
                                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                                std::vector<uint8_t> jp2;
                                (void)encodeJp2Grok(&jp2, pixels.data(), cropW, cropH, (size_t)cropW, true, quality);
                                if (!jp2.empty())
                                    pagesPtr[pageNum].image.bytes = std::move(jp2);
                                dispatch_semaphore_signal(sem);
                            }
                        });
                    }
                }
                else
                {
                    // Convert RGB to grayscale for Otsu content detection
                    std::vector<unsigned char> grayForCrop = rgb24ToGrayscale(rgb.data(), renderW, renderH, rowBytes);

                    // Try Otsu cropping, fallback to full page if it fails
                    CropRect cr = { 0, 0, renderW, renderH };
                    CropRect otsuCrop{};
                    if (findContentRectOtsu(grayForCrop.data(), renderW, renderH, (size_t)renderW, &otsuCrop))
                    {
                        padCropRect(&otsuCrop, CropPad, renderW, renderH);
                        if (otsuCrop.x1 - otsuCrop.x0 > 0 && otsuCrop.y1 - otsuCrop.y0 > 0)
                            cr = otsuCrop;
                    }

                    int cropW = cr.x1 - cr.x0;
                    int cropH = cr.y1 - cr.y0;
                    std::vector<uint8_t> pixels = extractRgbCrop(rgb.data(), rowBytes, cr);

                    p.image.kind = DjvuPdfImageKind::Jp2;
                    p.image.gray = false;
                    p.image.w = cropW;
                    p.image.h = cropH;
                    setPdfPlacementForCrop(&p.image, renderW, renderH, cr, p.pdfWidth, p.pdfHeight);

                    // Use DjVu page type for quality selection
                    Jp2Quality quality = pageTypeToQuality(pageType);

                    dispatch_group_async(encGroup, encQ, ^{
                        @autoreleasepool
                        {
                        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                        std::vector<uint8_t> jp2;
                        (void)encodeJp2Grok(&jp2, pixels.data(), cropW, cropH, (size_t)cropW * 3U, false, quality);
                        if (!jp2.empty())
                                pagesPtr[pageNum].image.bytes = std::move(jp2);
                            dispatch_semaphore_signal(sem);
                        }
                    });
                }
            }

            ddjvu_page_release(page);

            incrementDonePagesForPath(djvuPath);
        }
    }

    // Wait for all JP2 encoding to complete
    dispatch_group_wait(encGroup, DISPATCH_TIME_FOREVER);

    // Clean up PIXes if there was an error
    if (!ok && !jbig2Batch.pixes.empty())
    {
        for (auto*& pix : jbig2Batch.pixes)
            pixDestroy(&pix);
        jbig2Batch.pixes.clear();
        jbig2Batch.pageNums.clear();
    }

    if (ok)
    {
        for (int i = 0; i < pageCount && ok; ++i)
        {
            // Check compound page background encoding
            if (pagesPtr[i].bgImage.kind == DjvuPdfImageKind::Jp2 && pagesPtr[i].bgImage.bytes.empty())
            {
                NSLog(@"DjvuConverter ERROR: JP2 encoding failed for compound page %d background in %@", i, djvuPath);
                ok = false;
            }
            // Check regular page JP2 encoding
            else if (pagesPtr[i].image.kind == DjvuPdfImageKind::Jp2 && pagesPtr[i].image.bytes.empty())
            {
                NSLog(@"DjvuConverter ERROR: JP2 encoding failed for page %d in %@", i, djvuPath);
                ok = false;
            }
        }
    }

    // Flush remaining JBIG2 batch
    if (ok && !jbig2Batch.pixes.empty())
    {
        flushJbig2BatchAsync(std::move(jbig2Batch), &jbig2Ctx);
        jbig2Batch = Jbig2Batch{};
    }

    // Wait for all async JBIG2 encoding to complete
    dispatch_group_wait(jbig2Ctx.group, DISPATCH_TIME_FOREVER);

    // Check JBIG2 async status
    if (!jbig2Ctx.ok)
        ok = false;

    if (ok)
    {
        ok = writePdfDeterministic(tmpPdfPath, pages, jbig2Globals, outline);
        if (!ok)
            NSLog(@"DjvuConverter ERROR: writePdfDeterministic failed for %@", djvuPath);
    }

    ddjvu_format_release(rgb24);
    ddjvu_format_release(grey8);
    ddjvu_format_release(msb);
    ddjvu_document_release(doc);
    ddjvu_context_release(ctx);

    return ok ? YES : NO;
}

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

    // Dispatch conversions via the shared path so we can track "active" vs "pending" work.
    [self ensureConversionDispatchedForTorrent:torrent];
}

+ (void)clearTrackingForTorrent:(Torrent*)torrent
{
    if (!torrent)
        return;

    NSString* hash = torrent.hashString;
    [sLastScanTime removeObjectForKey:hash];
    [sConversionQueue removeObjectForKey:hash];
    [sFailedConversions removeObjectForKey:hash];
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

                // Mark active when the worker actually begins (use async to avoid deadlock)
                dispatch_async(dispatch_get_main_queue(), ^{
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

    // Collect files to remove (can't modify set while iterating)
    NSMutableArray<NSString*>* toRemove = [NSMutableArray array];
    NSString* firstFailed = nil;

    for (NSString* djvuPath in failedFiles)
    {
        // If a PDF exists now, clear the failure entry
        NSString* pdfPath = [djvuPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
        if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
        {
            [toRemove addObject:djvuPath];
            continue;
        }

        if (firstFailed == nil)
            firstFailed = djvuPath.lastPathComponent;
    }

    // Remove files that now have PDFs
    for (NSString* path in toRemove)
        [failedFiles removeObject:path];

    return firstFailed;
}

+ (void)clearFailedConversionsForTorrent:(Torrent*)torrent
{
    if (!torrent || !sFailedConversions)
        return;

    [sFailedConversions removeObjectForKey:torrent.hashString];
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

+ (NSArray<NSString*>*)convertedFilesForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return @[];

    NSMutableArray<NSString*>* convertedFiles = [NSMutableArray array];
    NSArray<FileListNode*>* fileList = torrent.flatFileList;

    for (FileListNode* node in fileList)
    {
        NSString* ext = node.name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"djvu"] && ![ext isEqualToString:@"djv"])
            continue;

        NSString* path = [torrent fileLocation:node];
        if (!path)
            continue;

        NSString* pdfPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
        if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
            [convertedFiles addObject:pdfPath];
    }

    return convertedFiles;
}

@end
