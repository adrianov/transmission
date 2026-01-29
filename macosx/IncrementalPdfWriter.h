// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <Foundation/Foundation.h>

#include <cstdarg>
#include <cstdio>
#include <atomic>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <memory>

enum class DjvuPdfImageKind
{
    None,
    Jpeg,
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

    // Encoded bytes. For JPEG: DCTDecode stream. For JBIG2: JBIG2Decode page stream.
    std::vector<uint8_t> bytes;
};

struct DjvuPdfPageInfo
{
    double pdfWidth = 0.0;
    double pdfHeight = 0.0;
    DjvuPdfImageInfo image;
    // For compound pages: background picture layer + foreground text mask overlay
    DjvuPdfImageInfo bgImage; // Background: JPEG grayscale/RGB
    DjvuPdfImageInfo fgMask; // JBIG2 ImageMask (transparent bg)
};

struct OutlineNode
{
    std::string title;
    int rawPage = -1; // numeric page reference when not directly resolved
    int pageIndex = -1; // resolved 0-based page index
    std::vector<OutlineNode> children;
};

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

inline OutlineBuildResult buildOutlineItems(std::vector<PdfOutlineItem>* items, std::vector<OutlineNode> const& nodes, int parent)
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

inline std::string pdfEscapeString(std::string_view text)
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

inline void appendHexByte(std::string* out, unsigned char value)
{
    static char constexpr Hex[] = "0123456789ABCDEF";
    out->push_back(Hex[value >> 4]);
    out->push_back(Hex[value & 0x0F]);
}

inline std::string pdfOutlineTitle(std::string_view text)
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

struct PageObjs
{
    int img = 0; // Single image (non-compound) or unused for compound
    int bgImg = 0; // Background image for compound pages
    int fgMask = 0; // Foreground mask for compound pages
    int contents = 0;
    int page = 0;
};

// Incremental PDF writer - builds PDF in memory, then writes once to disk (no temp file).
struct IncrementalPdfWriter
{
    std::vector<uint8_t> buffer_;
    int nextObj = 1;
    int catalogObj = 0;
    int pagesObj = 0;
    int infoObj = 0;
    int outlinesObj = 0;
    std::vector<int> jbig2GlobalsObjs;
    std::vector<PageObjs> pageObjs;
    std::vector<uint64_t> offsets;
    std::vector<PdfOutlineItem> outlineItems;
    std::vector<int> outlineObjs;
    OutlineBuildResult outlineResult;
    std::unordered_map<std::string, std::string> metadata;
    mutable std::mutex writeMutex; // Protect file writes
    std::vector<bool> pagesWritten; // Track which pages have been written
    bool initialized = false;
    std::atomic<bool> finalized{ false }; // Track if PDF has been finalized

    void appendStr(std::string_view s)
    {
        buffer_.insert(buffer_.end(), s.data(), s.data() + s.size());
    }

    void appendFmt(char const* fmt, ...)
    {
        char stack[2048];
        va_list ap;
        va_start(ap, fmt);
        int n = vsnprintf(stack, sizeof(stack), fmt, ap);
        va_end(ap);
        if (n <= 0)
            return;
        if ((size_t)n < sizeof(stack))
            buffer_.insert(buffer_.end(), stack, stack + n);
        else
        {
            std::vector<char> heap((size_t)n + 1);
            va_start(ap, fmt);
            vsnprintf(heap.data(), heap.size(), fmt, ap);
            va_end(ap);
            buffer_.insert(buffer_.end(), heap.data(), heap.data() + n);
        }
    }

    void appendBytes(uint8_t const* bytes, size_t len)
    {
        if (len > 0)
            buffer_.insert(buffer_.end(), bytes, bytes + len);
    }

    bool init(
        int pageCount,
        std::vector<std::vector<uint8_t>> const& jbig2Globals,
        std::vector<OutlineNode> const& outlineNodes,
        std::unordered_map<std::string, std::string> const& meta,
        int estimatedMaxJbig2Globals = 0)
    {
        if (pageCount <= 0)
            return false;

        buffer_.clear();
        metadata = meta;
        pageObjs.resize((size_t)pageCount);
        pagesWritten.resize((size_t)pageCount, false);

        appendStr("%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");

        // Reserve object numbers
        catalogObj = nextObj++;
        pagesObj = nextObj++;
        infoObj = nextObj++;

        // Reserve object numbers for JBIG2 globals (they'll be created dynamically)
        // Use estimated max or actual size, whichever is larger
        size_t const maxGlobals = MAX(jbig2Globals.size(), (size_t)estimatedMaxJbig2Globals);
        jbig2GlobalsObjs.resize(maxGlobals, 0);
        for (size_t i = 0; i < maxGlobals; ++i)
        {
            // Reserve object numbers for all potential globals
            jbig2GlobalsObjs[i] = nextObj++;
        }

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

        // Reserve object numbers for all pages (we'll determine structure when writing)
        for (int i = 0; i < pageCount; ++i)
        {
            // Reserve space for worst case: compound page (bgImg + fgMask + contents + page)
            pageObjs[i].bgImg = nextObj++;
            pageObjs[i].fgMask = nextObj++;
            pageObjs[i].img = nextObj++;
            pageObjs[i].contents = nextObj++;
            pageObjs[i].page = nextObj++;
        }

        int const objCount = nextObj - 1;
        offsets.resize((size_t)objCount + 1U, 0);

        initialized = true;
        return true;
    }

    void writeObjBegin(int objNum)
    {
        offsets[(size_t)objNum] = (uint64_t)buffer_.size();
        appendFmt("%d 0 obj\n", objNum);
    }

    void writeObjEnd()
    {
        appendStr("endobj\n");
    }

    void writeStreamObj(int objNum, char const* dictPrefix, uint8_t const* bytes, size_t len)
    {
        writeObjBegin(objNum);
        appendFmt("%s/Length %zu >>\nstream\n", dictPrefix, len);
        appendBytes(bytes, len);
        appendStr("\nendstream\n");
        writeObjEnd();
    }

    bool writePage(int pageIndex, DjvuPdfPageInfo const& p)
    {
        if (!initialized)
            return false;

        std::lock_guard<std::mutex> lock(writeMutex);

        // Skip if page already written
        if ((size_t)pageIndex < pagesWritten.size() && pagesWritten[(size_t)pageIndex])
            return true;

        PageObjs& o = pageObjs[(size_t)pageIndex];
        bool const isCompound =
            (p.bgImage.kind != DjvuPdfImageKind::None && !p.bgImage.bytes.empty() && p.fgMask.kind != DjvuPdfImageKind::None &&
             !p.fgMask.bytes.empty());

        // Adjust object numbers if not compound (reuse unused slots)
        if (!isCompound)
        {
            o.bgImg = 0;
            o.fgMask = 0;
            if (p.image.kind == DjvuPdfImageKind::None || p.image.bytes.empty())
                o.img = 0;
        }
        else
        {
            o.img = 0;
        }

        if (isCompound)
        {
            DjvuPdfImageInfo const& bgImg = p.bgImage;
            writeObjBegin(o.bgImg);
            char const* bgCs = bgImg.gray ? "/DeviceGray" : "/DeviceRGB";
            appendFmt(
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8 /Filter /DCTDecode /Length %zu >>\nstream\n",
                bgImg.w,
                bgImg.h,
                bgCs,
                (size_t)bgImg.bytes.size());
            appendBytes(bgImg.bytes.data(), bgImg.bytes.size());
            appendStr("\nendstream\n");
            writeObjEnd();

            DjvuPdfImageInfo const& fgMask = p.fgMask;
            if (fgMask.jbig2GlobalsIndex < 0 || (size_t)fgMask.jbig2GlobalsIndex >= jbig2GlobalsObjs.size())
                return false;
            int const fgGlobalsObj = jbig2GlobalsObjs[(size_t)fgMask.jbig2GlobalsIndex];
            if (fgGlobalsObj == 0)
                return false;
            writeObjBegin(o.fgMask);
            appendFmt(
                "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms << /JBIG2Globals %d 0 R >> /Length %zu >>\nstream\n",
                fgMask.w,
                fgMask.h,
                fgGlobalsObj,
                (size_t)fgMask.bytes.size());
            appendBytes(fgMask.bytes.data(), fgMask.bytes.size());
            appendStr("\nendstream\n");
            writeObjEnd();
        }
        else if (o.img != 0)
        {
            DjvuPdfImageInfo const& img = p.image;
            writeObjBegin(o.img);
            if (img.kind == DjvuPdfImageKind::Jpeg)
            {
                char const* cs = img.gray ? "/DeviceGray" : "/DeviceRGB";
                appendFmt(
                    "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace %s /BitsPerComponent 8 /Filter /DCTDecode /Length %zu >>\nstream\n",
                    img.w,
                    img.h,
                    cs,
                    (size_t)img.bytes.size());
            }
            else if (img.kind == DjvuPdfImageKind::Jbig2)
            {
                if (img.jbig2GlobalsIndex < 0 || (size_t)img.jbig2GlobalsIndex >= jbig2GlobalsObjs.size())
                {
                    writeObjEnd();
                    return false;
                }
                int const globalsObj = jbig2GlobalsObjs[(size_t)img.jbig2GlobalsIndex];
                if (globalsObj == 0)
                {
                    writeObjEnd();
                    return false;
                }
                appendFmt(
                    "<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /DecodeParms << /JBIG2Globals %d 0 R >> /Length %zu >>\nstream\n",
                    img.w,
                    img.h,
                    globalsObj,
                    (size_t)img.bytes.size());
            }
            appendBytes(img.bytes.data(), img.bytes.size());
            appendStr("\nendstream\n");
            writeObjEnd();
        }

        // Page contents
        std::string contents;
        contents.reserve(256);
        if (isCompound)
        {
            DjvuPdfImageInfo const& bgImg = p.bgImage;
            DjvuPdfImageInfo const& fgMask = p.fgMask;
            char tmp[256];
            snprintf(tmp, sizeof(tmp), "q\n%g 0 0 %g %g %g cm\n/BgIm Do\nQ\n", bgImg.pdfW, bgImg.pdfH, bgImg.x, bgImg.y);
            contents.append(tmp);
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

        writeObjBegin(o.page);
        appendFmt("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %g %g] ", pagesObj, p.pdfWidth, p.pdfHeight);
        appendStr("/Resources << ");
        if (isCompound)
        {
            appendStr("/XObject << ");
            appendFmt("/BgIm %d 0 R /FgMask %d 0 R ", o.bgImg, o.fgMask);
            appendStr(">> ");
        }
        else if (o.img != 0)
        {
            appendStr("/XObject << ");
            appendFmt("/Im %d 0 R ", o.img);
            appendStr(">> ");
        }
        appendFmt(">> /Contents %d 0 R >>\n", o.contents);
        writeObjEnd();

        // Mark page as written
        if ((size_t)pageIndex < pagesWritten.size())
            pagesWritten[(size_t)pageIndex] = true;

        return true;
    }

    // Check if all pages are written
    bool allPagesWritten() const
    {
        if (!initialized || pagesWritten.empty())
            return false;

        std::lock_guard<std::mutex> lock(writeMutex);
        for (bool written : pagesWritten)
        {
            if (!written)
                return false;
        }
        return true;
    }

    // Check if PDF has been finalized
    bool isFinalized() const
    {
        return finalized;
    }

    bool finalize(std::vector<std::vector<uint8_t>> const& jbig2Globals)
    {
        if (!initialized)
            return false;

        std::lock_guard<std::mutex> lock(writeMutex);

        writeObjBegin(catalogObj);
        if (outlinesObj != 0)
            appendFmt("<< /Type /Catalog /Pages %d 0 R /Outlines %d 0 R /PageMode /UseOutlines >>\n", pagesObj, outlinesObj);
        else
            appendFmt("<< /Type /Catalog /Pages %d 0 R >>\n", pagesObj);
        writeObjEnd();

        writeObjBegin(pagesObj);
        appendStr("<< /Type /Pages /Kids [");
        for (size_t i = 0; i < pageObjs.size(); ++i)
        {
            if (pageObjs[i].page != 0)
                appendFmt(" %d 0 R", pageObjs[i].page);
        }
        appendFmt(" ] /Count %zu >>\n", pageObjs.size());
        writeObjEnd();

        if (outlinesObj != 0)
        {
            writeObjBegin(outlinesObj);
            if (outlineResult.first != -1)
                appendFmt(
                    "<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count %d >>\n",
                    outlineObjs[(size_t)outlineResult.first],
                    outlineObjs[(size_t)outlineResult.last],
                    outlineResult.descendants);
            else
                appendStr("<< /Type /Outlines >>\n");
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
                appendFmt(
                    "<< /Title %s /Parent %d 0 R /Dest [%d 0 R /Fit]",
                    titleToken.c_str(),
                    parentObj,
                    pageObjs[(size_t)pageIndex].page);
                if (item.prev != -1)
                    appendFmt(" /Prev %d 0 R", outlineObjs[(size_t)item.prev]);
                if (item.next != -1)
                    appendFmt(" /Next %d 0 R", outlineObjs[(size_t)item.next]);
                if (item.firstChild != -1)
                    appendFmt(
                        " /First %d 0 R /Last %d 0 R /Count %d",
                        outlineObjs[(size_t)item.firstChild],
                        outlineObjs[(size_t)item.lastChild],
                        item.count);
                appendStr(" >>\n");
                writeObjEnd();
            }
        }

        for (size_t i = 0; i < jbig2Globals.size(); ++i)
        {
            int obj = jbig2GlobalsObjs[i];
            if (obj != 0)
                writeStreamObj(obj, "<< ", jbig2Globals[i].data(), jbig2Globals[i].size());
        }

        writeObjBegin(infoObj);
        appendStr("<< ");
        auto const writeField = [&](char const* pdfKey, char const* djvuKey)
        {
            auto it = metadata.find(djvuKey);
            if (it != metadata.end())
            {
                appendFmt("%s %s ", pdfKey, pdfOutlineTitle(it->second).c_str());
                return true;
            }
            return false;
        };
        writeField("/Title", "title");
        writeField("/Author", "author");
        if (!writeField("/Subject", "subject"))
            writeField("/Subject", "description");
        writeField("/Keywords", "keywords");
        if (!writeField("/Creator", "creator"))
            writeField("/Creator", "producer");
        if (!writeField("/CreationDate", "date"))
            writeField("/CreationDate", "year");
        appendStr("/Producer (Transmission) ");
        static std::unordered_set<std::string> const knownKeys = { "title",   "author", "subject", "description", "keywords",
                                                                   "creator", "date",   "year",    "producer" };
        for (auto const& [key, value] : metadata)
        {
            if (knownKeys.find(key) == knownKeys.end())
            {
                std::string const customKey = "/" + pdfEscapeString(key);
                appendFmt("%s %s ", customKey.c_str(), pdfOutlineTitle(value).c_str());
            }
        }
        appendStr(">>\n");
        writeObjEnd();

        uint64_t const xrefOffset = (uint64_t)buffer_.size();
        int const objCount = nextObj - 1;
        appendFmt("xref\n0 %d\n0000000000 65535 f \n", objCount + 1);
        for (int i = 1; i <= objCount; ++i)
        {
            if ((size_t)i < offsets.size() && offsets[(size_t)i] != 0)
                appendFmt("%010llu 00000 n \n", (unsigned long long)offsets[(size_t)i]);
            else
                appendStr("0000000000 00000 n \n");
        }
        appendFmt("trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%llu\n%%%%EOF\n", objCount + 1, catalogObj, infoObj, (unsigned long long)xrefOffset);
        finalized = true;
        return true;
    }

    // Write full PDF buffer to path in one shot (no temp file, no extra copy). Call only after finalize().
    bool writeToFile(NSString* path) const
    {
        if (!finalized || buffer_.empty() || path == nil)
            return false;
        char const* utf8 = [path UTF8String];
        if (!utf8)
            return false;
        FILE* f = fopen(utf8, "wb");
        if (!f)
            return false;
        bool ok = fwrite(buffer_.data(), 1, buffer_.size(), f) == buffer_.size();
        fclose(f);
        if (!ok && utf8[0] != '\0')
            remove(utf8);
        return ok;
    }

    ~IncrementalPdfWriter() = default;
};
