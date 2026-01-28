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
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
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
#include <turbojpeg.h>

#import "IncrementalPdfWriter.h"

// Track files that have been queued for conversion (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sConversionQueue = nil;
static NSMutableDictionary<NSString*, NSNumber*>* sLastScanTime = nil;
static dispatch_queue_t sConversionDispatchQueue = nil;
static dispatch_semaphore_t sConversionSemaphore = nil;

// Global semaphore to limit concurrent JBIG2 encoding across all files
// Each file has its own serial queue, but we limit total concurrent batches
// to prevent thread pool exhaustion
static dispatch_semaphore_t sJbig2Semaphore = nil;

// Global tracking for cross-torrent concurrency control.
// Some DJVU files might need to wait for pages in all DJVUs across all transfers
// before they can write a final PDF.
static NSMutableSet<NSString*>* sActiveConversions = nil;
static NSMutableSet<NSString*>* sPendingConversions = nil;
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sFailedConversions = nil;
static NSMutableDictionary<NSString*, NSString*>* sFailedConversionErrors = nil; // Maps djvuPath -> error message
static dispatch_queue_t sTrackingQueue = nil;
static void const* const sTrackingQueueKey = &sTrackingQueueKey;

// Helper to safely dispatch to sTrackingQueue, avoiding deadlocks
static void safeDispatchSync(dispatch_block_t block)
{
    if (dispatch_get_specific(sTrackingQueueKey) == sTrackingQueueKey)
    {
        // Already on the tracking queue, execute directly
        block();
    }
    else
    {
        dispatch_sync(sTrackingQueue, block);
    }
}

static void setFailedConversionError(NSString* djvuPath, NSString* message)
{
    if (djvuPath == nil || message == nil || message.length == 0 || sTrackingQueue == nil)
        return;

    safeDispatchSync(^{
        if (!sFailedConversionErrors)
            sFailedConversionErrors = [NSMutableDictionary dictionary];
        if (sFailedConversionErrors[djvuPath] == nil)
            sFailedConversionErrors[djvuPath] = message;
    });
}

static NSString* firstFailedPathForTorrent(Torrent* torrent)
{
    if (!torrent || torrent.magnet || !sFailedConversions || !sTrackingQueue)
        return nil;

    NSString* torrentHash = torrent.hashString;
    __block NSMutableSet<NSString*>* failedFiles = nil;
    __block NSString* firstFailed = nil;
    __block NSMutableArray<NSString*>* toRemove = [NSMutableArray array];

    safeDispatchSync(^{
        failedFiles = sFailedConversions[torrentHash];
        if (!failedFiles || failedFiles.count == 0)
            return;

        for (NSString* djvuPath in failedFiles)
        {
            NSString* pdfPath = [djvuPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
            if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
            {
                [toRemove addObject:djvuPath];
                continue;
            }

            if (firstFailed == nil)
                firstFailed = djvuPath;
        }

        for (NSString* path in toRemove)
        {
            [failedFiles removeObject:path];
            [sFailedConversionErrors removeObjectForKey:path];
        }
    });

    return firstFailed;
}
static NSMutableDictionary<NSString*, NSNumber*>* sConversionTotalPages = nil;
static NSMutableDictionary<NSString*, NSNumber*>* sConversionDonePages = nil;

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

static std::unordered_map<std::string, std::string> readDjvuMetadata(ddjvu_context_t* ctx, ddjvu_document_t* doc)
{
    std::unordered_map<std::string, std::string> metadata;
    if (ctx == nullptr || doc == nullptr)
    {
        return metadata;
    }

    miniexp_t exp = miniexp_dummy;
    while (exp == miniexp_dummy)
    {
        exp = ddjvu_document_get_anno(doc, TRUE);
        if (exp == miniexp_dummy)
        {
            ddjvu_message_t* msg = ddjvu_message_wait(ctx);
            if (msg)
            {
                ddjvu_message_pop(ctx);
            }
        }
    }

    if (exp == miniexp_nil)
    {
        return metadata;
    }

    if (miniexp_symbolp(exp))
    {
        char const* name = miniexp_to_name(exp);
        if (name != nullptr && (strcmp(name, "failed") == 0 || strcmp(name, "stopped") == 0))
        {
            ddjvu_miniexp_release(doc, exp);
            return metadata;
        }
    }

    miniexp_t list = exp;
    while (miniexp_consp(list))
    {
        miniexp_t entry = miniexp_car(list);
        if (miniexp_consp(entry) && miniexp_symbolp(miniexp_car(entry)))
        {
            char const* head = miniexp_to_name(miniexp_car(entry));
            if (head != nullptr && strcmp(head, "metadata") == 0)
            {
                miniexp_t fields = miniexp_cdr(entry);
                while (miniexp_consp(fields))
                {
                    miniexp_t field = miniexp_car(fields);
                    if (miniexp_consp(field) && miniexp_symbolp(miniexp_car(field)) && miniexp_stringp(miniexp_cadr(field)))
                    {
                        char const* key = miniexp_to_name(miniexp_car(field));
                        char const* val = miniexp_to_str(miniexp_cadr(field));
                        if (key != nullptr && val != nullptr)
                        {
                            std::string k = key;
                            std::transform(k.begin(), k.end(), k.begin(), [](unsigned char c) { return (char)std::tolower(c); });
                            metadata[k] = val;
                        }
                    }
                    fields = miniexp_cdr(fields);
                }
            }
        }
        list = miniexp_cdr(list);
    }

    ddjvu_miniexp_release(doc, exp);
    return metadata;
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

// Map DjVu page type to JPEG quality
static int pageTypeToJpegQuality(ddjvu_page_type_t pageType)
{
    switch (pageType)
    {
    case DDJVU_PAGETYPE_BITONAL:
        return 95; // Near-bitonal that didn't go to JBIG2
    case DDJVU_PAGETYPE_PHOTO:
        return 85; // Smooth photographs
    case DDJVU_PAGETYPE_COMPOUND:
        return 90; // Mixed content
    default:
        return 90;
    }
}

static bool encodeJpegTurbo(std::vector<uint8_t>* out, unsigned char const* pixels, int w, int h, size_t stride, bool gray, int quality, NSString* djvuPath = nil, int pageNum = -1)
{
    if (out == nullptr || pixels == nullptr || w <= 0 || h <= 0 || stride == 0)
    {
        if (djvuPath && pageNum >= 0)
            NSLog(@"DjvuConverter ERROR: invalid parameters for JPEG encoding (w=%d h=%d stride=%zu) page %d in %@", w, h, stride, pageNum, djvuPath);
        setFailedConversionError(djvuPath, @"Invalid JPEG encode parameters");
        return false;
    }

    // libjpeg-turbo is thread-safe as long as each thread uses its own handle.
    tjhandle handle = tjInitCompress();
    if (handle == nullptr)
    {
        if (djvuPath && pageNum >= 0)
            NSLog(@"DjvuConverter ERROR: tjInitCompress failed for page %d in %@", pageNum, djvuPath);
        setFailedConversionError(djvuPath, @"JPEG encoder init failed");
        return false;
    }

    unsigned char* jpegBuf = nullptr;
    unsigned long jpegSize = 0;

    int const pixelFormat = gray ? TJPF_GRAY : TJPF_RGB;
    int const subsamp = gray ? TJSAMP_GRAY : TJSAMP_444;

    int const ret = tjCompress2(handle, pixels, w, (int)stride, h, pixelFormat, &jpegBuf, &jpegSize, subsamp, quality, TJFLAG_FASTDCT);

    bool ok = (ret == 0 && jpegBuf != nullptr && jpegSize > 0);
    if (!ok && djvuPath && pageNum >= 0)
    {
        char const* errMsg = tjGetErrorStr2(handle);
        NSLog(@"DjvuConverter ERROR: tjCompress2 failed (ret=%d size=%lu) for page %d in %@: %s", ret, jpegSize, pageNum, djvuPath, errMsg ? errMsg : "unknown");
        setFailedConversionError(djvuPath, [NSString stringWithFormat:@"JPEG encode failed (page %d)", pageNum]);
    }

    if (ok)
        out->assign(jpegBuf, jpegBuf + jpegSize);

    if (jpegBuf != nullptr)
        tjFree(jpegBuf);

    tjDestroy(handle);
    return ok;
}

struct Jbig2Batch
{
    std::vector<PIX*> pixes;
    std::vector<int> pageNums;
};

// Async JBIG2 encoding context - ONE PER FILE
// IMPORTANT: Each file must have its own context to ensure:
// 1. Pages from different files never mix in the same batch
// 2. Batches from the same file are processed sequentially (via queue)
// 3. Pages within each batch are consecutive from the same file
struct Jbig2AsyncContext
{
    dispatch_group_t group;
    dispatch_queue_t queue; // Per-file serial queue for JBIG2 batches - ensures batches are sequential
    std::mutex mutex; // Protects pages and globals
    std::vector<DjvuPdfPageInfo>* pages;
    std::vector<std::vector<uint8_t>>* globals;
    std::shared_ptr<IncrementalPdfWriter> pdfWriter;
    std::atomic<bool> ok{ true };
    NSString* djvuPath;
    int pageCount = 0; // Total pages expected
    std::atomic<bool> jbig2Complete{ false }; // Track if all JBIG2 batches are complete
};

// Encode a batch of pages from ONE file using JBIG2
// CRITICAL CONSTRAINTS:
// 1. All pages in this batch MUST be from the same file (same ctx->djvuPath)
// 2. Pages should be consecutive within the file for proper encoding
// 3. Maximum 20 pages per batch (jbig2enc library limitation)
// 4. Each batch creates its own jbig2ctx instance
static void flushJbig2BatchAsync(Jbig2Batch batch, std::shared_ptr<Jbig2AsyncContext> ctx)
{
    if (batch.pixes.empty() || ctx == nullptr)
    {
        for (auto*& pix : batch.pixes)
            pixDestroy(&pix);
        return;
    }

    dispatch_group_async(ctx->group, ctx->queue, ^{
        // Limit concurrent JBIG2 encoding across all files to avoid thread pool exhaustion
        // This semaphore prevents too many CPU-intensive JBIG2 operations from blocking GCD threads
        if (sJbig2Semaphore)
            dispatch_semaphore_wait(sJbig2Semaphore, DISPATCH_TIME_FOREVER);

        // Each file has its own serial queue, so batches from the same file are sequential
        // This ensures consecutive pages are processed in order
        // Pages from different files never mix in the same batch
        // Different files use different queues and can encode in parallel

        NSDate* batchStartTime = [NSDate date];
        NSLog(@"DjvuConverter: Starting JBIG2 batch with %zu images for %@", batch.pixes.size(), ctx->djvuPath);

        // Create a new jbig2ctx for this batch
        // CONSTRAINT: Can only add pages from ONE file, maximum 20 pages
        jbig2ctx* jb2 = jbig2_init(0.85f, 0.5f, 0, 0, false, -1);
        if (jb2 == nullptr)
        {
            NSLog(@"DjvuConverter ERROR: jbig2_init failed for %@", ctx->djvuPath);
            setFailedConversionError(ctx->djvuPath, @"JBIG2 init failed");
            for (auto* pix : batch.pixes)
                pixDestroy(&pix);
            ctx->ok = false;
            if (sJbig2Semaphore)
                dispatch_semaphore_signal(sJbig2Semaphore);
            return;
        }

        // Add all pages from this batch to the jbig2 context
        // All pages are from the same file and are consecutive
        for (auto* pix : batch.pixes)
            jbig2_add_page(jb2, pix);

        int globalsLen = 0;
        uint8_t* globalsBuf = jbig2_pages_complete(jb2, &globalsLen);
        if (globalsBuf == nullptr || globalsLen <= 0)
        {
            NSLog(@"DjvuConverter ERROR: jbig2_pages_complete failed for %@", ctx->djvuPath);
            setFailedConversionError(ctx->djvuPath, @"JBIG2 globals encode failed");
            jbig2_destroy(jb2);
            for (auto* pix : batch.pixes)
                pixDestroy(&pix);
            ctx->ok = false;
            if (sJbig2Semaphore)
                dispatch_semaphore_signal(sJbig2Semaphore);
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
                setFailedConversionError(ctx->djvuPath, @"JBIG2 page encode failed");
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

        // Count unique page indices in this batch
        std::unordered_set<int> uniquePageIndices;
        for (int rawPageNum : batch.pageNums)
        {
            int pageIndex = (rawPageNum < 0) ? (-1 - rawPageNum) : rawPageNum;
            uniquePageIndices.insert(pageIndex);
        }

        // Increment done pages for all unique pages in this batch
        int pagesCompleted = (int)uniquePageIndices.size();
        for (int i = 0; i < pagesCompleted; ++i)
            incrementDonePagesForPath(ctx->djvuPath);

        NSTimeInterval elapsed = -[batchStartTime timeIntervalSinceNow];
        NSLog(@"DjvuConverter: Completed JBIG2 batch for %@ (%d pages in %.1f seconds)", ctx->djvuPath, pagesCompleted, elapsed);

        // Release semaphore to allow next JBIG2 batch to start
        if (sJbig2Semaphore)
            dispatch_semaphore_signal(sJbig2Semaphore);
    });
}

static BOOL convertDjvuFileDeterministic(NSString* djvuPath, NSString* tmpPdfPath)
{
    if (!djvuPath || djvuPath.length == 0)
    {
        NSLog(@"DjvuConverter ERROR: invalid DJVU path");
        setFailedConversionError(djvuPath, @"Invalid DJVU path");
        return NO;
    }

    // Create DJVU context
    ddjvu_context_t* ctx = ddjvu_context_create("Transmission");
    if (!ctx)
    {
        NSLog(@"DjvuConverter ERROR: failed to create DJVU context for %@", djvuPath);
        setFailedConversionError(djvuPath, @"Failed to create DJVU context");
        return NO;
    }

    // DjvuLib document and page operations are generally thread-safe on the same context,
    // but message handling must be coordinated.
    char const* utf8Path = djvuPath.UTF8String;
    if (!utf8Path)
    {
        NSLog(@"DjvuConverter ERROR: failed to get UTF8 string from path: %@", djvuPath);
        setFailedConversionError(djvuPath, @"Failed to read DJVU path");
        ddjvu_context_release(ctx);
        return NO;
    }

    ddjvu_document_t* doc = ddjvu_document_create_by_filename_utf8(ctx, utf8Path, TRUE);
    if (!doc)
    {
        NSLog(@"DjvuConverter ERROR: failed to open DJVU document: %@", djvuPath);
        setFailedConversionError(djvuPath, @"Failed to open DJVU document");
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
        setFailedConversionError(djvuPath, @"DJVU document decoding failed");
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    int pageCount = ddjvu_document_get_pagenum(doc);
    if (pageCount <= 0)
    {
        NSLog(@"DjvuConverter ERROR: invalid page count (%d) for %@", pageCount, djvuPath);
        setFailedConversionError(djvuPath, @"Invalid page count");
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    setTotalPagesForPath(djvuPath, pageCount);

    std::vector<OutlineNode> outline = readDjvuOutline(ctx, doc, pageCount);
    std::unordered_map<std::string, std::string> metadata = readDjvuMetadata(ctx, doc);

    // Vector of all page data - automatically freed when function returns
    // This can be large (hundreds of MB for JPEG/JBIG2 encoded pages)
    std::vector<DjvuPdfPageInfo> pages((size_t)pageCount);
    DjvuPdfPageInfo* pagesPtr = pages.data();

    ddjvu_format_t* rgb24 = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, nullptr);
    ddjvu_format_t* grey8 = ddjvu_format_create(DDJVU_FORMAT_GREY8, 0, nullptr);
    ddjvu_format_t* msb = ddjvu_format_create(DDJVU_FORMAT_MSBTOLSB, 0, nullptr);
    if (!rgb24 || !grey8 || !msb)
    {
        NSLog(@"DjvuConverter ERROR: failed to create pixel format for %@", djvuPath);
        setFailedConversionError(djvuPath, @"Failed to create pixel format");
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

    dispatch_queue_t encQ = dispatch_queue_create("transmission.djvu.jpeg.encode", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t encGroup = dispatch_group_create();

    // Allow concurrent JPEG encodes up to CPU count
    // JPEG encoding is fast and separate from JBIG2, so we can use full CPU count
    NSInteger cpu = NSProcessInfo.processInfo.activeProcessorCount;
    NSInteger maxJpegConcurrent = MAX(4, cpu);
    dispatch_semaphore_t sem = dispatch_semaphore_create(maxJpegConcurrent);

    bool ok = true;
    // Smaller batches = more parallelism, larger = better symbol sharing
    // JBIG2 ENCODING CONSTRAINTS:
    // 1. Maximum 20 pages per jbig2ctx (library limitation)
    // 2. All pages in a batch must be from THIS FILE ONLY (no mixing files)
    // 3. Pages should be consecutive for optimal encoding
    //
    // Balance JBIG2 encoding speed vs. file size:
    // - Small batches (10) = fast but +200KB (many globals dictionaries)
    // - Larger batches (20) = better compression, fewer globals
    // Cap at 20 pages per batch due to jbig2enc constraints
    int const Jbig2BatchSize = MIN(20, MAX(10, pageCount / 20)); // 10-20 pages per batch
    // Use shared_ptr for batch and mutex to ensure they live as long as the lambda
    auto jbig2Batch = std::make_shared<Jbig2Batch>();
    auto jbig2BatchMutex = std::make_shared<std::mutex>();
    // JBIG2 globals dictionaries - one per batch, automatically freed when function returns
    // This grows as batches complete, but is released after PDF finalization
    std::vector<std::vector<uint8_t>> jbig2Globals;

    // Initialize incremental PDF writer early - we'll write pages as they complete
    // Estimate max JBIG2 globals (one per batch, worst case: one per page)
    int const estimatedMaxJbig2Globals = (pageCount + Jbig2BatchSize - 1) / Jbig2BatchSize;
    jbig2Globals.reserve((size_t)estimatedMaxJbig2Globals);

    auto pdfWriterPtr = std::make_shared<IncrementalPdfWriter>();
    if (!pdfWriterPtr->init(tmpPdfPath, pageCount, jbig2Globals, outline, metadata, estimatedMaxJbig2Globals))
    {
        NSLog(@"DjvuConverter ERROR: failed to initialize PDF writer for %@", djvuPath);
        setFailedConversionError(djvuPath, @"Failed to initialize PDF writer");
        ddjvu_format_release(rgb24);
        ddjvu_format_release(grey8);
        ddjvu_format_release(msb);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    // Helper to safely add to jbig2Batch and flush if needed (defined after jbig2Ctx)
    std::function<void(int, PIX*)> addToJbig2Batch;

    // Async JBIG2 context - allows overlapping JBIG2 encoding with page rendering
    // Each file uses a serial queue for its batches, running in separate helper processes
    // Different files can encode in parallel since each uses a separate process
    // Create JBIG2 context for THIS FILE ONLY
    // IMPORTANT: This context is used for ALL batches from this file
    // - Each batch will create its own jbig2ctx (max 20 pages)
    // - Batches are processed sequentially on this file's queue
    // - Pages from different files NEVER mix in the same batch
    auto jbig2Ctx = std::make_shared<Jbig2AsyncContext>();
    jbig2Ctx->group = dispatch_group_create();
    // Each file gets its own serial queue for JBIG2 batches
    // This ensures batches from the same file are processed sequentially (consecutive pages)
    // Different files use different queues and can encode in parallel
    jbig2Ctx->queue = dispatch_queue_create("com.transmissionbt.djvuconverter.jbig2.file", DISPATCH_QUEUE_SERIAL);
    jbig2Ctx->pages = &pages;
    jbig2Ctx->globals = &jbig2Globals;
    jbig2Ctx->pdfWriter = pdfWriterPtr;
    jbig2Ctx->djvuPath = djvuPath;
    jbig2Ctx->pageCount = pageCount;

    // Now define the lambda after jbig2Ctx is available
    // Capture mutex and batch by value (shared_ptr) to ensure they live as long as needed
    // Release lock before async call to avoid holding lock during async operation
    // Use a weak_ptr to avoid extending lifetime unintentionally
    std::weak_ptr<Jbig2AsyncContext> jbig2CtxWeak = jbig2Ctx;
    addToJbig2Batch = [jbig2Batch, jbig2BatchMutex, jbig2CtxWeak, Jbig2BatchSize](int pageNum, PIX* pix)
    {
        Jbig2Batch batchToFlush;
        bool shouldFlush = false;

        {
            std::lock_guard<std::mutex> lock(*jbig2BatchMutex);
            jbig2Batch->pageNums.push_back(pageNum);
            jbig2Batch->pixes.push_back(pix);
            if ((int)jbig2Batch->pixes.size() >= Jbig2BatchSize)
            {
                batchToFlush = std::move(*jbig2Batch);
                *jbig2Batch = Jbig2Batch{};
                shouldFlush = true;
            }
        }

        // Release lock before async call
        if (shouldFlush)
        {
            if (auto ctx = jbig2CtxWeak.lock())
            {
                flushJbig2BatchAsync(std::move(batchToFlush), ctx);
            }
            else
            {
                for (auto* p : batchToFlush.pixes)
                    pixDestroy(&p);
            }
        }
    };

    // Parallelize page rendering - create concurrent queue for page processing
    // Leptonica and libjpeg-turbo are thread-safe for these operations.
    dispatch_queue_t pageRenderQueue = dispatch_queue_create("transmission.djvu.page.render", DISPATCH_QUEUE_CONCURRENT);
    dispatch_group_t pageRenderGroup = dispatch_group_create();
    std::atomic<bool>* pageRenderOkPtr = new std::atomic<bool>(true);

    // First, decode all pages in parallel where possible.
    // ddjvu_page_create_by_pageno and ddjvu_message_wait are thread-safe on the context.
    // Use custom deleter to automatically clean up pages, document and context.
    // The deleter captures doc and ctx to ensure they live as long as the pages.
    auto decodedPages = std::shared_ptr<std::vector<ddjvu_page_t*>>(
        new std::vector<ddjvu_page_t*>((size_t)pageCount, nullptr),
        [doc, ctx](std::vector<ddjvu_page_t*>* pages)
        {
            if (pages != nullptr)
            {
                for (auto* page : *pages)
                {
                    if (page != nullptr)
                        ddjvu_page_release(page);
                }
                delete pages;
            }
            if (doc != nullptr)
                ddjvu_document_release(doc);
            if (ctx != nullptr)
                ddjvu_context_release(ctx);
        });
    auto decodedPagesMutex = std::make_shared<std::mutex>();
    std::vector<ddjvu_page_t*>* decodedPagesPtr = decodedPages.get();
    dispatch_queue_t decodeQueue = dispatch_queue_create("transmission.djvu.page.decode", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t decodeGroup = dispatch_group_create();

    for (int pageNum = 0; pageNum < pageCount; ++pageNum)
    {
        dispatch_group_async(decodeGroup, decodeQueue, ^{
            ddjvu_page_t* page = ddjvu_page_create_by_pageno(doc, pageNum);
            if (!page)
            {
                NSLog(@"DjvuConverter ERROR: failed to create page %d in %@", pageNum, djvuPath);
                setFailedConversionError(djvuPath, @"Failed to decode a page");
                return;
            }

            while (!ddjvu_page_decoding_done(page))
            {
                // We need to wait for messages on the context for this page.
                // ddjvu_message_wait is blocking.
                // DjvuLib context message queue is shared; use a serial queue for decoding to avoid
                // multiple threads waiting on the same context simultaneously which can be problematic.
                ddjvu_message_t* msg = ddjvu_message_wait(ctx);
                if (msg)
                    ddjvu_message_pop(ctx);
            }

            if (ddjvu_page_decoding_error(page))
            {
                NSLog(@"DjvuConverter ERROR: page %d decoding failed in %@", pageNum, djvuPath);
                setFailedConversionError(djvuPath, @"Page decoding failed");
                ddjvu_page_release(page);
                return;
            }

            std::lock_guard<std::mutex> lock(*decodedPagesMutex);
            (*decodedPagesPtr)[(size_t)pageNum] = page;
        });
    }
    dispatch_group_wait(decodeGroup, DISPATCH_TIME_FOREVER);

    // Check if all pages were decoded successfully
    for (int pageNum = 0; pageNum < pageCount; ++pageNum)
    {
        if ((*decodedPages)[(size_t)pageNum] == nullptr)
        {
            ok = false;
            break;
        }
    }

    if (!ok)
    {
        // decodedPages will be automatically cleaned up by shared_ptr deleter
        // which also handles releasing doc and ctx
        ddjvu_format_release(rgb24);
        ddjvu_format_release(grey8);
        ddjvu_format_release(msb);
        return NO;
    }

    // All pages are decoded and we've extracted outline/metadata.
    // doc and ctx will be released by decodedPages deleter when all pages are done.

    // Now process all decoded pages in parallel
    // Capture variables needed in the block
    DjvuPdfPageInfo* capturedPagesPtr = pagesPtr;
    ddjvu_format_t* capturedRgb24 = rgb24;
    ddjvu_format_t* capturedGrey8 = grey8;
    ddjvu_format_t* capturedMsb = msb;
    NSString* capturedDjvuPath = djvuPath;
    dispatch_group_t capturedEncGroup = encGroup;
    dispatch_queue_t capturedEncQ = encQ;
    dispatch_semaphore_t capturedSem = sem;
    auto capturedAddToJbig2Batch = addToJbig2Batch;

    for (int pageNum = 0; pageNum < pageCount; ++pageNum)
    {
        ddjvu_page_t* page = (*decodedPages)[(size_t)pageNum];
        int capturedPageNum = pageNum; // Capture by value
        dispatch_group_async(pageRenderGroup, pageRenderQueue, ^{
            @autoreleasepool
            {
                if (!pageRenderOkPtr->load())
                {
                    return;
                }

                ddjvu_page_type_t pageType = ddjvu_page_get_type(page);
                int pageWidth = ddjvu_page_get_width(page);
                int pageHeight = ddjvu_page_get_height(page);
                int pageDpi = ddjvu_page_get_resolution(page);
                if (pageWidth <= 0 || pageHeight <= 0 || pageDpi <= 0)
                {
                    NSLog(@"DjvuConverter ERROR: invalid page dimensions (w=%d h=%d dpi=%d) for page %d in %@", pageWidth, pageHeight, pageDpi, capturedPageNum, capturedDjvuPath);
                    setFailedConversionError(capturedDjvuPath, @"Invalid page dimensions");
                    pageRenderOkPtr->store(false);
                    return;
                }

                DjvuPdfPageInfo& p = capturedPagesPtr[capturedPageNum];
                p.pdfWidth = (double)pageWidth * 72.0 / (double)pageDpi;
                p.pdfHeight = (double)pageHeight * 72.0 / (double)pageDpi;

                int constexpr MaxRenderDpi = 300;
                int renderDpi = MIN(MaxRenderDpi, pageDpi);
                int renderW = 0;
                int renderH = 0;
                computeRenderDimensions(pageWidth, pageHeight, pageDpi, renderDpi, &renderW, &renderH);
                if (renderW <= 0 || renderH <= 0)
                {
                    pageRenderOkPtr->store(false);
                    return;
                }

                // Handle compound pages (text over picture) specially
                if (pageType == DDJVU_PAGETYPE_COMPOUND)
                {
                    // Check if full-page composite (photo) is bitonal when considered alone; used for merge decision.
                    bool fullPageBitonal = false;
                    int checkW = 0;
                    int checkH = 0;
                    int const checkDpi = MAX(1, MIN((int)(512.0 * pageDpi / (double)MAX(pageWidth, pageHeight)), pageDpi));
                    computeRenderDimensions(pageWidth, pageHeight, pageDpi, checkDpi, &checkW, &checkH);
                    if (checkW > 0 && checkH > 0)
                    {
                        size_t checkRowBytes = (size_t)checkW * 3U;
                        std::vector<uint8_t> checkRgb(checkRowBytes * (size_t)checkH, (uint8_t)0xFF);
                        ddjvu_rect_t checkRect = { 0, 0, (unsigned int)checkW, (unsigned int)checkH };
                        int checkRendered = ddjvu_page_render(
                            page,
                            DDJVU_RENDER_COLOR,
                            &checkRect,
                            &checkRect,
                            capturedRgb24,
                            (unsigned long)checkRowBytes,
                            (char*)checkRgb.data());
                        fullPageBitonal = (checkRendered != 0) && isGrayscaleRgb24(checkRgb.data(), checkW, checkH, checkRowBytes) &&
                            isBitonalGrayscaleRgb(checkRgb.data(), checkW, checkH, checkRowBytes);
                    }

                    // Render foreground text mask to check if compound mode is worthwhile
                    double maskCoverage = 0.0;
                    bool const preferBitonal = (renderDpi == pageDpi) && (renderW == pageWidth) && (renderH == pageHeight);
                    NSData* fgPbm = renderDjvuMaskPbmData(page, capturedGrey8, capturedMsb, renderW, renderH, preferBitonal, &maskCoverage);
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
                            capturedRgb24,
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
                                fgCrop = { MAX(0, bx - CropPad),
                                           MAX(0, by - CropPad),
                                           MIN(fgFullW, bx + bw + CropPad),
                                           MIN(fgFullH, by + bh + CropPad) };
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
                                        bgCrop = { MAX(0, bx - CropPad),
                                                   MAX(0, by - CropPad),
                                                   MIN(bgW, bx + bw + CropPad),
                                                   MIN(bgH, by + bh + CropPad) };
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
                                // Merge only when separately just background or full-page photo is bitonal; otherwise two-layer
                                bool const bgIsBitonal = isBitonalGrayscaleRgb(bgRgb.data(), bgW, bgH, bgRowBytes);
                                if (bgIsBitonal || fullPageBitonal)
                                {
                                    // Merge bitonal: binarize background at render size, OR with text mask → single JBIG2 per page
                                    PIX* bgGrayMerge = pixCreate(bgW, bgH, 8);
                                    if (bgGrayMerge != nullptr)
                                    {
                                        if (bgGray)
                                        {
                                            for (int y = 0; y < bgH; ++y)
                                            {
                                                auto const* srcRow = bgRgb.data() + (size_t)y * bgRowBytes;
                                                l_uint32* dstRow = pixGetData(bgGrayMerge) + y * pixGetWpl(bgGrayMerge);
                                                for (int x = 0; x < bgW; ++x)
                                                    SET_DATA_BYTE(dstRow, x, srcRow[x * 3]);
                                            }
                                        }
                                        else
                                        {
                                            std::vector<unsigned char> grayBuf = rgb24ToGrayscale(bgRgb.data(), bgW, bgH, bgRowBytes);
                                            for (int y = 0; y < bgH; ++y)
                                            {
                                                auto const* srcRow = grayBuf.data() + (size_t)y * (size_t)bgW;
                                                l_uint32* dstRow = pixGetData(bgGrayMerge) + y * pixGetWpl(bgGrayMerge);
                                                for (int x = 0; x < bgW; ++x)
                                                    SET_DATA_BYTE(dstRow, x, srcRow[x]);
                                            }
                                        }
                                        float const sx = (float)renderW / (float)bgW;
                                        float const sy = (float)renderH / (float)bgH;
                                        PIX* scaledBg = pixScale(bgGrayMerge, sx, sy);
                                        pixDestroy(&bgGrayMerge);
                                        if (scaledBg != nullptr && pixGetWidth(scaledBg) == renderW && pixGetHeight(scaledBg) == renderH)
                                        {
                                            int constexpr MergeThresh = 128;
                                            PIX* bgBinMerge = pixThresholdToBinary(scaledBg, MergeThresh);
                                            pixDestroy(&scaledBg);
                                            if (bgBinMerge != nullptr)
                                            {
                                                PIX* merged = pixOr(nullptr, bgBinMerge, fgPix);
                                                pixDestroy(&bgBinMerge);
                                                if (merged != nullptr)
                                                {
                                                    BOX* mergeBox = nullptr;
                                                    if (pixClipToForeground(merged, nullptr, &mergeBox) == 0 && mergeBox != nullptr)
                                                    {
                                                        l_int32 bx, by, bw, bh;
                                                        boxGetGeometry(mergeBox, &bx, &by, &bw, &bh);
                                                        int const x0 = MAX(0, (int)bx - CropPad);
                                                        int const y0 = MAX(0, (int)by - CropPad);
                                                        int const x1 = MIN(renderW, (int)bx + (int)bw + CropPad);
                                                        int const y1 = MIN(renderH, (int)by + (int)bh + CropPad);
                                                        BOX* clipBox = boxCreate(x0, y0, x1 - x0, y1 - y0);
                                                        PIX* mergedCropped = (clipBox != nullptr) ?
                                                            pixClipRectangle(merged, clipBox, nullptr) :
                                                            nullptr;
                                                        boxDestroy(&clipBox);
                                                        boxDestroy(&mergeBox);
                                                        pixDestroy(&merged);
                                                        if (mergedCropped != nullptr && pixGetWidth(mergedCropped) > 0 &&
                                                            pixGetHeight(mergedCropped) > 0)
                                                        {
                                                            CropRect const mergeCrop{ x0, y0, x1, y1 };
                                                            p.image.kind = DjvuPdfImageKind::Jbig2;
                                                            p.image.w = pixGetWidth(mergedCropped);
                                                            p.image.h = pixGetHeight(mergedCropped);
                                                            setPdfPlacementForCrop(&p.image, renderW, renderH, mergeCrop, p.pdfWidth, p.pdfHeight);
                                                            capturedAddToJbig2Batch(capturedPageNum, mergedCropped);
                                                            pixDestroy(&fgPix);
                                                            incrementDonePagesForPath(capturedDjvuPath);
                                                            return;
                                                        }
                                                        if (mergedCropped != nullptr)
                                                            pixDestroy(&mergedCropped);
                                                    }
                                                    else
                                                    {
                                                        if (mergeBox != nullptr)
                                                            boxDestroy(&mergeBox);
                                                        pixDestroy(&merged);
                                                    }
                                                }
                                            }
                                            else
                                                pixDestroy(&scaledBg);
                                        }
                                        else if (scaledBg != nullptr)
                                            pixDestroy(&scaledBg);
                                    }
                                }
                                // If background is not bitonal, fall through to two-layer encoding (JPEG + JBIG2)

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
                                p.bgImage.kind = DjvuPdfImageKind::Jpeg;
                                p.bgImage.gray = bgGray;
                                p.bgImage.w = bgCropW;
                                p.bgImage.h = bgCropH;
                                p.bgImage.x = bgPdfX;
                                p.bgImage.y = bgPdfY;
                                p.bgImage.pdfW = bgPdfW;
                                p.bgImage.pdfH = bgPdfH;

                                // Encode cropped background as JPEG
                                if (bgGray)
                                {
                                    std::vector<unsigned char> grayBuf = rgb24ToGrayscale(bgRgb.data(), bgW, bgH, bgRowBytes);
                                    std::vector<unsigned char> croppedGray = extractGrayCrop(grayBuf.data(), bgW, bgCrop);
                                    dispatch_group_async(capturedEncGroup, capturedEncQ, ^{
                                        @autoreleasepool
                                        {
                                            dispatch_semaphore_wait(capturedSem, DISPATCH_TIME_FOREVER);
                                            std::vector<uint8_t> jpeg;
                                            bool bgEncoded = encodeJpegTurbo(&jpeg, croppedGray.data(), bgCropW, bgCropH, (size_t)bgCropW, true, 60, capturedDjvuPath, capturedPageNum);
                                            if (bgEncoded && !jpeg.empty())
                                            {
                                                capturedPagesPtr[capturedPageNum].bgImage.bytes = std::move(jpeg);
                                                // Page will be written after all processing is complete
                                            }
                                            dispatch_semaphore_signal(capturedSem);
                                        }
                                    });
                                }
                                else
                                {
                                    std::vector<uint8_t> croppedBg = extractRgbCrop(bgRgb.data(), bgRowBytes, bgCrop);
                                    dispatch_group_async(capturedEncGroup, capturedEncQ, ^{
                                        @autoreleasepool
                                        {
                                            dispatch_semaphore_wait(capturedSem, DISPATCH_TIME_FOREVER);
                                            std::vector<uint8_t> jpeg;
                                            bool bgEncoded = encodeJpegTurbo(&jpeg, croppedBg.data(), bgCropW, bgCropH, (size_t)bgCropW * 3U, false, 60, capturedDjvuPath, capturedPageNum);
                                            if (bgEncoded && !jpeg.empty())
                                            {
                                                capturedPagesPtr[capturedPageNum].bgImage.bytes = std::move(jpeg);
                                                // Page will be written after all processing is complete
                                            }
                                            dispatch_semaphore_signal(capturedSem);
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
                                    // Negative page number to indicate it's a foreground mask
                                    capturedAddToJbig2Batch(-1 - capturedPageNum, fgCropped);

                                    incrementDonePagesForPath(capturedDjvuPath);
                                    return; // Skip normal rendering path
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
                            capturedRgb24,
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
                        // Check bitonal: trust page type first, then check rendered content
                        // Skip bitonal check for PHOTO pages - they should stay as JPEG
                        bool const bitonal = (pageType != DDJVU_PAGETYPE_PHOTO) &&
                            (pageType == DDJVU_PAGETYPE_BITONAL || isBitonalGrayscaleRgb(rgb.data(), renderW, renderH, rowBytes));
                        if (bitonal)
                        {
                            bool const preferBitonal = (renderDpi == pageDpi) && (renderW == pageWidth) && (renderH == pageHeight);
                            NSData* pbm = renderDjvuMaskPbmData(page, capturedGrey8, capturedMsb, renderW, renderH, preferBitonal, nullptr);
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
                                        capturedAddToJbig2Batch(capturedPageNum, pixCropped);
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

                            // If mask rendering failed for a bitonal page, binarize the grayscale content
                            if (p.image.kind == DjvuPdfImageKind::None && bitonal)
                            {
                                std::vector<unsigned char> grayBuf = rgb24ToGrayscale(rgb.data(), renderW, renderH, rowBytes);

                                // Binarize using Otsu threshold
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
                                std::vector<unsigned char> cropGray = extractGrayCrop(grayBuf.data(), renderW, cr);

                                // Convert to 1-bit PIX
                                PIX* pixGray = pixCreate(cropW, cropH, 8);
                                if (pixGray != nullptr)
                                {
                                    for (int y = 0; y < cropH; ++y)
                                    {
                                        l_uint32* dstRow = pixGetData(pixGray) + (size_t)y * pixGetWpl(pixGray);
                                        auto const* src = cropGray.data() + (size_t)y * (size_t)cropW;
                                        for (int x = 0; x < cropW; ++x)
                                            SET_DATA_BYTE(dstRow, x, src[x]);
                                    }

                                    // Binarize using Otsu adaptive threshold
                                    PIX* pix1 = nullptr;
                                    pixOtsuAdaptiveThreshold(pixGray, 0, 0, 0, 0, 0.0f, nullptr, &pix1);
                                    pixDestroy(&pixGray);

                                    if (pix1 != nullptr && pixGetWidth(pix1) > 0 && pixGetHeight(pix1) > 0)
                                    {
                                        p.image.kind = DjvuPdfImageKind::Jbig2;
                                        p.image.w = pixGetWidth(pix1);
                                        p.image.h = pixGetHeight(pix1);
                                        setPdfPlacementForCrop(&p.image, renderW, renderH, cr, p.pdfWidth, p.pdfHeight);
                                        capturedAddToJbig2Batch(capturedPageNum, pix1);
                                    }
                                    else if (pix1 != nullptr)
                                    {
                                        pixDestroy(&pix1);
                                    }
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

                            p.image.kind = DjvuPdfImageKind::Jpeg;
                            p.image.gray = true;
                            p.image.w = cropW;
                            p.image.h = cropH;
                            setPdfPlacementForCrop(&p.image, renderW, renderH, cr, p.pdfWidth, p.pdfHeight);

                            // Use DjVu page type for quality selection
                            int quality = pageTypeToJpegQuality(pageType);

                            dispatch_group_async(encGroup, encQ, ^{
                                @autoreleasepool
                                {
                                    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                                    std::vector<uint8_t> encoded;
                                    bool encodedOk = encodeJpegTurbo(&encoded, pixels.data(), cropW, cropH, (size_t)cropW, true, quality, capturedDjvuPath, capturedPageNum);
                                    if (encodedOk)
                                    {
                                        capturedPagesPtr[capturedPageNum].image.bytes = std::move(encoded);
                                        incrementDonePagesForPath(capturedDjvuPath);
                                    }
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

                        p.image.kind = DjvuPdfImageKind::Jpeg;
                        p.image.gray = false;
                        p.image.w = cropW;
                        p.image.h = cropH;
                        setPdfPlacementForCrop(&p.image, renderW, renderH, cr, p.pdfWidth, p.pdfHeight);

                        // Use DjVu page type for quality selection
                        int quality = pageTypeToJpegQuality(pageType);

                        dispatch_group_async(encGroup, encQ, ^{
                            @autoreleasepool
                            {
                                dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                                std::vector<uint8_t> encoded;
                                bool encodedOk = encodeJpegTurbo(&encoded, pixels.data(), cropW, cropH, (size_t)cropW * 3U, false, quality, capturedDjvuPath, pageNum);
                                if (encodedOk)
                                {
                                    pagesPtr[pageNum].image.bytes = std::move(encoded);
                                    incrementDonePagesForPath(capturedDjvuPath);
                                }
                                dispatch_semaphore_signal(sem);
                            }
                        });
                    }
                }
                // Note: Don't increment done pages here - pages are incremented when their encoding completes
                // For JBIG2 pages: incremented in flushJbig2BatchAsync after batch encoding
                // For JPEG pages: incremented in the JPEG encoding async block
            }
        });
    }

    // Wait for all page rendering to complete
    dispatch_group_wait(pageRenderGroup, DISPATCH_TIME_FOREVER);
    if (!pageRenderOkPtr->load())
        ok = false;
    delete pageRenderOkPtr;

    // Wait for all JPEG encoding to complete
    dispatch_group_wait(encGroup, DISPATCH_TIME_FOREVER);

    // Clean up PIXes if there was an error
    if (!ok)
    {
        std::lock_guard<std::mutex> lock(*jbig2BatchMutex);
        if (!jbig2Batch->pixes.empty())
        {
            for (auto*& pix : jbig2Batch->pixes)
                pixDestroy(&pix);
            jbig2Batch->pixes.clear();
            jbig2Batch->pageNums.clear();
        }
    }

    if (ok)
    {
        for (int i = 0; i < pageCount && ok; ++i)
        {
            // Check compound page background encoding
            if (pagesPtr[i].bgImage.kind == DjvuPdfImageKind::Jpeg && pagesPtr[i].bgImage.bytes.empty())
            {
                NSLog(@"DjvuConverter ERROR: JPEG encoding failed for compound page %d background in %@", i, djvuPath);
                setFailedConversionError(djvuPath, @"JPEG encoding failed");
                ok = false;
            }
            // Check regular page encoding
            else if (pagesPtr[i].image.kind == DjvuPdfImageKind::Jpeg && pagesPtr[i].image.bytes.empty())
            {
                NSLog(@"DjvuConverter ERROR: JPEG encoding failed for page %d in %@", i, djvuPath);
                setFailedConversionError(djvuPath, @"JPEG encoding failed");
                ok = false;
            }
        }
    }

    // Flush remaining JBIG2 batch
    if (ok)
    {
        Jbig2Batch batchToFlush;
        {
            std::lock_guard<std::mutex> lock(*jbig2BatchMutex);
            if (!jbig2Batch->pixes.empty())
            {
                batchToFlush = std::move(*jbig2Batch);
                *jbig2Batch = Jbig2Batch{};
            }
        }
        // Release lock before async call
        if (!batchToFlush.pixes.empty())
        {
            flushJbig2BatchAsync(std::move(batchToFlush), jbig2Ctx);
        }
        // Mark JBIG2 as complete - no more batches will be added
        jbig2Ctx->jbig2Complete = true;
    }
    else
    {
        // Even on error, mark as complete to avoid waiting forever
        jbig2Ctx->jbig2Complete = true;
    }

    // Wait for all async JBIG2 encoding to complete for THIS file
    // Ensure all JBIG2 work finishes before continuing to avoid use-after-free
    // Scale timeout with page count: ~2 seconds per page for JBIG2 encoding
    double timeoutSeconds = MAX(180.0, pageCount * 2.0);
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC));
    NSLog(@"DjvuConverter: Waiting for JBIG2 completion for %@ (timeout: %.0f seconds)", djvuPath, timeoutSeconds);
    if (dispatch_group_wait(jbig2Ctx->group, timeout) != 0)
    {
        NSLog(@"DjvuConverter WARNING: timeout (%.0fs) waiting for JBIG2 encoding for %@", timeoutSeconds, djvuPath);
        setFailedConversionError(djvuPath, @"JBIG2 encoding timed out");
        ok = false;
        // Still wait for completion to keep async work from using freed state
        NSLog(@"DjvuConverter: Waiting indefinitely for JBIG2 to complete for %@...", djvuPath);
        dispatch_group_wait(jbig2Ctx->group, DISPATCH_TIME_FOREVER);
        NSLog(@"DjvuConverter: JBIG2 eventually completed for %@", djvuPath);
    }
    else
    {
        NSLog(@"DjvuConverter: JBIG2 encoding completed for %@", djvuPath);
    }

    // Check JBIG2 async status
    if (!jbig2Ctx->ok.load())
    {
        NSLog(@"DjvuConverter ERROR: JBIG2 encoding failed for %@", djvuPath);
        setFailedConversionError(djvuPath, @"JBIG2 encoding failed");
        ok = false;
    }

    if (ok)
    {
        // Validate all pages have valid dimensions before writing
        for (int i = 0; i < pageCount; ++i)
        {
            DjvuPdfPageInfo const& p = pagesPtr[i];
            if (p.pdfWidth <= 0.0 || p.pdfHeight <= 0.0)
            {
                NSLog(@"DjvuConverter ERROR: page %d has invalid dimensions (%.2f x %.2f) for %@", i, p.pdfWidth, p.pdfHeight, djvuPath);
                setFailedConversionError(djvuPath, @"Invalid page dimensions");
                ok = false;
                break;
            }
        }

        // Write all pages now that all processing is complete
        if (ok)
        {
            NSLog(@"DjvuConverter: Writing %d pages to PDF for %@", pageCount, djvuPath);
            for (int i = 0; i < pageCount; ++i)
            {
                DjvuPdfPageInfo const& p = pagesPtr[i];
                if (!pdfWriterPtr->writePage(i, p))
                {
                    NSLog(@"DjvuConverter ERROR: failed to write page %d for %@", i, djvuPath);
                    setFailedConversionError(djvuPath, @"Failed to write PDF page");
                    ok = false;
                    break;
                }
            }
        }

        // Finalize PDF after all pages are written
        if (ok && !pdfWriterPtr->isFinalized())
        {
            NSLog(@"DjvuConverter: Finalizing PDF for %@", djvuPath);
            ok = pdfWriterPtr->finalize(jbig2Globals);
            if (!ok)
            {
                NSLog(@"DjvuConverter ERROR: PDF finalization failed for %@", djvuPath);
                setFailedConversionError(djvuPath, @"PDF finalization failed");
            }
            else
            {
                NSLog(@"DjvuConverter: Successfully finalized PDF for %@", djvuPath);
            }
        }
    }

    ddjvu_format_release(rgb24);
    ddjvu_format_release(grey8);
    ddjvu_format_release(msb);
    // doc and ctx are handled by decodedPages deleter

    // Clean up dispatch resources
    // Note: dispatch_group_t and dispatch_queue_t are automatically managed by ARC
    // but we ensure they're fully released by clearing the jbig2Ctx shared_ptr
    // This will release the queue and group when the last reference is dropped
    // The shared_ptr goes out of scope here, triggering cleanup

    return ok ? YES : NO;
}

@implementation DjvuConverter

+ (void)initialize
{
    if (self == [DjvuConverter class])
    {
        sConversionQueue = [NSMutableDictionary dictionary];
        sLastScanTime = [NSMutableDictionary dictionary];
        // Use concurrent queue to allow multiple file conversions in parallel
        // Limit concurrency: each file conversion has internal parallelism for pages,
        // so we limit file conversions to avoid overwhelming the GCD thread pool
        NSInteger cpu = NSProcessInfo.processInfo.activeProcessorCount;
        // With per-file serial queues for JBIG2, we can run more files in parallel safely
        // Each file uses internal parallelism for pages, but JBIG2 batches are serialized per-file
        NSInteger maxConcurrent = MAX(2, MIN(8, cpu));
        dispatch_queue_attr_t attrs = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0);
        sConversionDispatchQueue = dispatch_queue_create("com.transmissionbt.djvuconverter", attrs);
        sConversionSemaphore = dispatch_semaphore_create(maxConcurrent);

        // Limit concurrent JBIG2 batches to CPU count
        // Each file has its own serial queue for batches, but we limit total concurrency
        // JBIG2 encoding is CPU-intensive, so limit to available cores
        NSInteger maxJbig2Concurrent = MAX(2, cpu);
        sJbig2Semaphore = dispatch_semaphore_create(maxJbig2Concurrent);

        // Serial queue for thread-safe tracking set operations
        sTrackingQueue = dispatch_queue_create("com.transmissionbt.djvuconverter.tracking", DISPATCH_QUEUE_SERIAL);
        // Set queue-specific key to detect if we're already on this queue
        dispatch_queue_set_specific(sTrackingQueue, sTrackingQueueKey, (void*)sTrackingQueueKey, nullptr);
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
        NSString* name = node.name;
        if (!name)
            continue;
        if ([name.pathExtension.lowercaseString isEqualToString:@"pdf"])
        {
            [pdfBaseNames addObject:name.stringByDeletingPathExtension.lowercaseString];
        }
    }

    NSMutableArray<NSDictionary*>* filesToConvert = [NSMutableArray array];

    for (FileListNode* node in fileList)
    {
        NSString* name = node.name;
        if (!name)
            continue;
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
    if (sTrackingQueue)
    {
        safeDispatchSync(^{
            [sFailedConversions removeObjectForKey:hash];
        });
    }
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

    // Find the first file that is actively converting and PDF doesn't exist yet (thread-safe)
    __block NSString* result = nil;
    if (sTrackingQueue)
    {
        safeDispatchSync(^{
            for (NSString* djvuPath in queuedFiles)
            {
                if (![sActiveConversions containsObject:djvuPath])
                    continue;

                NSString* pdfPath = [djvuPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
                if (![NSFileManager.defaultManager fileExistsAtPath:pdfPath])
                {
                    // Return the filename (last path component)
                    result = djvuPath.lastPathComponent;
                    break;
                }
            }
        });
    }

    return result;
}

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

    if (sTrackingQueue)
    {
        safeDispatchSync(^{
            if (!sActiveConversions)
                sActiveConversions = [NSMutableSet set];
            if (!sFailedConversions)
                sFailedConversions = [NSMutableDictionary dictionary];
            if (!sFailedConversionErrors)
                sFailedConversionErrors = [NSMutableDictionary dictionary];
            if (!sPendingConversions)
                sPendingConversions = [NSMutableSet set];
            if (!sConversionTotalPages)
                sConversionTotalPages = [NSMutableDictionary dictionary];
            if (!sConversionDonePages)
                sConversionDonePages = [NSMutableDictionary dictionary];
        });
    }

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];

    if (!queuedFiles || queuedFiles.count == 0)
        return;

    // Thread-safe access to tracking sets
    __block NSMutableSet<NSString*>* failedForTorrent = nil;
    __block NSMutableArray<NSDictionary*>* filesToDispatch = [NSMutableArray array];

    if (!sTrackingQueue)
        return;

    safeDispatchSync(^{
        failedForTorrent = sFailedConversions[torrentHash];
        if (!failedForTorrent)
        {
            failedForTorrent = [NSMutableSet set];
            sFailedConversions[torrentHash] = failedForTorrent;
        }

        // Find files that are queued but not actively being converted
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
    });

    if (filesToDispatch.count == 0)
        return;

    NSString* notificationObject = [torrentHash copy];

    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary* file in filesToDispatch)
    {
        NSString* djvuPath = file[@"djvu"];
        NSString* pdfPath = file[@"pdf"];

        dispatch_group_async(group, sConversionDispatchQueue, ^{
            @autoreleasepool
            {
                // Wait for semaphore inside the block to control actual execution concurrency
                // This allows all files to be queued immediately, but only maxConcurrent run at once
                if (sConversionSemaphore)
                    dispatch_semaphore_wait(sConversionSemaphore, DISPATCH_TIME_FOREVER);

                BOOL success = YES;

                // Mark active when the worker actually begins (thread-safe)
                if (sTrackingQueue)
                {
                    safeDispatchSync(^{
                        [sPendingConversions removeObject:djvuPath];
                        [sActiveConversions addObject:djvuPath];
                    });
                }

                if (![NSFileManager.defaultManager fileExistsAtPath:pdfPath])
                {
                    success = [self convertDjvuFile:djvuPath toPdf:pdfPath];
                }

                // Remove from active set when done (thread-safe)
                if (sTrackingQueue)
                {
                    safeDispatchSync(^{
                        [sActiveConversions removeObject:djvuPath];
                        [sPendingConversions removeObject:djvuPath];
                        if (success)
                        {
                            [failedForTorrent removeObject:djvuPath];
                            clearPageTrackingForPath(djvuPath);
                            if (sFailedConversionErrors)
                                [sFailedConversionErrors removeObjectForKey:djvuPath];
                        }
                        else
                        {
                            [failedForTorrent addObject:djvuPath];
                            clearPageTrackingForPath(djvuPath);
                            // Store error message for UI display
                            if (!sFailedConversionErrors)
                                sFailedConversionErrors = [NSMutableDictionary dictionary];
                            if (sFailedConversionErrors[djvuPath] == nil)
                                sFailedConversionErrors[djvuPath] = @"Conversion failed";
                        }
                    });
                }

                // Signal semaphore after work is done
                if (sConversionSemaphore)
                    dispatch_semaphore_signal(sConversionSemaphore);

                // Notify completion for this specific file
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter postNotificationName:@"DjvuConversionComplete" object:notificationObject];
                });
            }
        });
    }
}

+ (NSString*)failedConversionFileNameForTorrent:(Torrent*)torrent
{
    NSString* failedPath = [self failedConversionPathForTorrent:torrent];
    return failedPath != nil ? failedPath.lastPathComponent : nil;
}

+ (NSString*)failedConversionPathForTorrent:(Torrent*)torrent
{
    return firstFailedPathForTorrent(torrent);
}

+ (NSString*)failedConversionErrorForPath:(NSString*)djvuPath
{
    if (djvuPath == nil || !sFailedConversionErrors || !sTrackingQueue)
        return nil;

    __block NSString* error = nil;
    safeDispatchSync(^{
        error = sFailedConversionErrors[djvuPath];
    });
    return error;
}

+ (void)clearFailedConversionsForTorrent:(Torrent*)torrent
{
    if (!torrent || !sFailedConversions || !sTrackingQueue)
        return;

    safeDispatchSync(^{
        [sFailedConversions removeObjectForKey:torrent.hashString];
    });
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

    // Thread-safe access to active conversions
    __block NSString* result = nil;
    if (sTrackingQueue)
    {
        safeDispatchSync(^{
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
                    result = [NSString stringWithFormat:@"%d of %d pages", donePages, totalPages];
                    break; // Exit the loop
                }
            }
        });
    }

    return result;
}

+ (BOOL)convertDjvuFile:(NSString*)djvuPath toPdf:(NSString*)pdfPath
{
    NSString* tmpPdfPath = [pdfPath stringByAppendingFormat:@".tmp-%@", NSUUID.UUID.UUIDString];

    BOOL success = convertDjvuFileDeterministic(djvuPath, tmpPdfPath);
    if (!success)
    {
        NSLog(@"DjvuConverter ERROR: conversion failed for %@", djvuPath);
        setFailedConversionError(djvuPath, @"Conversion failed");
        [NSFileManager.defaultManager removeItemAtPath:tmpPdfPath error:nil];
        return NO;
    }

    // Replace destination atomically to avoid ever exposing a partial PDF.
    [NSFileManager.defaultManager removeItemAtPath:pdfPath error:nil];
    NSError* moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:tmpPdfPath toPath:pdfPath error:&moveError])
    {
        NSLog(@"DjvuConverter ERROR: failed to move temp PDF to final location for %@: %@", djvuPath, moveError);
        setFailedConversionError(djvuPath, @"Failed to move PDF to final location");
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
