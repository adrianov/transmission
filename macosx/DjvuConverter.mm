// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "DjvuConverter.h"
#import "Torrent.h"
#import "FileListNode.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ddjvuapi.h>

#if HAVE_TURBOJPEG
#import <turbojpeg.h>
#endif

// Track files that have been queued for conversion (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sConversionQueue = nil;
static NSMutableDictionary<NSString*, NSNumber*>* sLastScanTime = nil;
static dispatch_queue_t sConversionDispatchQueue = nil;

static CGImageRef createImageFromEncodedData(NSData* data)
{
    if (data.length == 0)
        return nullptr;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!source)
        return nullptr;

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    return image;
}

static bool isTrulyBitonal(unsigned char const* bgra, int width, int height, size_t rowBytes)
{
    // Strict: only allow near-black and near-white pixels, with almost no gray shades.
    // This avoids misclassifying pages that have antialiasing or grayscale photos.
    unsigned char constexpr MinBlack = 16;
    unsigned char constexpr MinWhite = 239;
    int constexpr MaxChannelDelta = 2;

    int stepX = MAX(1, width / 512);
    int stepY = MAX(1, height / 512);

    for (int y = 0; y < height; y += stepY)
    {
        auto const* row = bgra + (size_t)y * rowBytes;
        for (int x = 0; x < width; x += stepX)
        {
            auto const b = row[x * 4 + 0];
            auto const g = row[x * 4 + 1];
            auto const r = row[x * 4 + 2];

            if (abs((int)r - (int)g) > MaxChannelDelta || abs((int)r - (int)b) > MaxChannelDelta)
                return false;

            auto const v = r; // grayscale
            if (v > MinBlack && v < MinWhite)
                return false;
        }
    }

    return true;
}

static bool isGrayscale(unsigned char const* bgra, int width, int height, size_t rowBytes)
{
    // Strict: only treat as grayscale when channels match very closely.
    // This avoids losing color information on slightly-tinted pages.
    int constexpr MaxChannelDelta = 2;

    int stepX = MAX(1, width / 512);
    int stepY = MAX(1, height / 512);

    for (int y = 0; y < height; y += stepY)
    {
        auto const* row = bgra + (size_t)y * rowBytes;
        for (int x = 0; x < width; x += stepX)
        {
            auto const b = row[x * 4 + 0];
            auto const g = row[x * 4 + 1];
            auto const r = row[x * 4 + 2];

            if (abs((int)r - (int)g) > MaxChannelDelta || abs((int)r - (int)b) > MaxChannelDelta)
                return false;
        }
    }

    return true;
}

static CGImageRef createTiffG4FromBitonal(unsigned char const* bgra, int width, int height, size_t rowBytes)
{
    // Convert to 1-bit MSB-first bitmap
    size_t bitRowBytes = ((size_t)width + 7U) / 8U;
    size_t bitSize = bitRowBytes * (size_t)height;
    auto* bits = (unsigned char*)calloc(bitSize, 1);
    if (!bits)
        return nullptr;

    for (int y = 0; y < height; ++y)
    {
        auto const* srcRow = bgra + (size_t)y * rowBytes;
        auto* dstRow = bits + (size_t)y * bitRowBytes;
        for (int x = 0; x < width; ++x)
        {
            unsigned char v = srcRow[x * 4 + 2]; // r
            if (v > 127)
            {
                dstRow[x / 8] |= (unsigned char)(0x80 >> (x % 8));
            }
        }
    }

    NSData* bitData = [[NSData alloc] initWithBytesNoCopy:bits length:bitSize freeWhenDone:YES];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bitData);
    if (!provider)
        return nullptr;

    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGImageRef bitImage = CGImageCreate(width, height, 1, 1, bitRowBytes, gray, kCGImageAlphaNone, provider, nullptr, false,
        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(gray);
    if (!bitImage)
        return nullptr;

    // Encode as TIFF CCITT Group 4
    NSMutableData* tiffData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)tiffData, (__bridge CFStringRef)UTTypeTIFF.identifier, 1, nullptr);
    if (!dest)
    {
        CGImageRelease(bitImage);
        return nullptr;
    }

    NSDictionary* props = @{ (__bridge id)kCGImagePropertyTIFFCompression : @4 };
    CGImageDestinationAddImage(dest, bitImage, (__bridge CFDictionaryRef)props);
    bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(bitImage);
    if (!ok)
        return nullptr;

    return createImageFromEncodedData(tiffData);
}

static CGImageRef createJpegFromGray(unsigned char const* gray, int width, int height, size_t rowBytes, int quality)
{
#if HAVE_TURBOJPEG
    tjhandle tj = tjInitCompress();
    if (!tj)
        return nullptr;

    unsigned char* jpegBuf = nullptr;
    unsigned long jpegSize = 0;
    int const rc = tjCompress2(
        tj,
        const_cast<unsigned char*>(gray),
        width,
        (int)rowBytes,
        height,
        TJPF_GRAY,
        &jpegBuf,
        &jpegSize,
        TJSAMP_GRAY,
        quality,
        TJFLAG_FASTDCT);
    tjDestroy(tj);

    if (rc != 0 || jpegBuf == nullptr || jpegSize == 0)
    {
        if (jpegBuf != nullptr)
            tjFree(jpegBuf);
        return nullptr;
    }

    NSData* jpegData = [NSData dataWithBytes:jpegBuf length:jpegSize];
    tjFree(jpegBuf);
    return createImageFromEncodedData(jpegData);
#else
    (void)gray;
    (void)width;
    (void)height;
    (void)rowBytes;
    (void)quality;
    return nullptr;
#endif
}

static CGImageRef createJpegFromBgra(unsigned char const* bgra, int width, int height, size_t rowBytes, int quality, int subsamp)
{
#if HAVE_TURBOJPEG
    tjhandle tj = tjInitCompress();
    if (!tj)
        return nullptr;

    unsigned char* jpegBuf = nullptr;
    unsigned long jpegSize = 0;
    int const rc = tjCompress2(
        tj,
        const_cast<unsigned char*>(bgra),
        width,
        (int)rowBytes,
        height,
        TJPF_BGRA,
        &jpegBuf,
        &jpegSize,
        subsamp,
        quality,
        TJFLAG_FASTDCT);
    tjDestroy(tj);

    if (rc != 0 || jpegBuf == nullptr || jpegSize == 0)
    {
        if (jpegBuf != nullptr)
            tjFree(jpegBuf);
        return nullptr;
    }

    // Copy JPEG data into NSData so we can tjFree() immediately.
    NSData* jpegData = [NSData dataWithBytes:jpegBuf length:jpegSize];
    tjFree(jpegBuf);
    return createImageFromEncodedData(jpegData);
#else
    (void)bgra;
    (void)width;
    (void)height;
    (void)rowBytes;
    (void)quality;
    (void)subsamp;
    return nullptr;
#endif
}

/// Cheap PDF sanity check.
/// Avoids CGPDFDocumentCreateWithURL() because it can be very slow and can run on the main thread
/// (e.g. when building playable file lists).
static BOOL isValidPdf(NSString* path)
{
    NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attrs)
        return NO;

    unsigned long long fileSize = attrs.fileSize;
    if (fileSize < 1024)
        return NO;

    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle)
        return NO;

    @autoreleasepool
    {
        NSData* header = [handle readDataOfLength:5];
        if (header.length != 5 || memcmp(header.bytes, "%PDF-", 5) != 0)
        {
            [handle closeFile];
            return NO;
        }

        unsigned long long tailLen = MIN(fileSize, 4096ULL);
        [handle seekToFileOffset:fileSize - tailLen];
        NSData* tail = [handle readDataToEndOfFile];
        [handle closeFile];
        if (tail.length == 0)
            return NO;

        auto const* bytes = static_cast<unsigned char const*>(tail.bytes);
        size_t const len = tail.length;
        for (size_t i = 0; i + 5 <= len; ++i)
        {
            if (memcmp(bytes + i, "%%EOF", 5) == 0)
            {
                return YES;
            }
        }

        return NO;
    }
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
        {
            [queuedFiles addObject:[torrent fileLocation:node] ?: name];
            continue;
        }

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

+ (BOOL)isValidPdf:(NSString*)path
{
    return isValidPdf(path);
}

+ (BOOL)convertDjvuFile:(NSString*)djvuPath toPdf:(NSString*)pdfPath
{
    NSString* tmpPdfPath = [pdfPath stringByAppendingFormat:@".tmp-%@", NSUUID.UUID.UUIDString];

    // Create DJVU context
    ddjvu_context_t* ctx = ddjvu_context_create("Transmission");
    if (!ctx)
        return NO;

    // Open document
    ddjvu_document_t* doc = ddjvu_document_create_by_filename_utf8(ctx, djvuPath.UTF8String, TRUE);
    if (!doc)
    {
        ddjvu_context_release(ctx);
        return NO;
    }

    // Wait for document to be decoded
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

    // Create PDF context (write to temp file, then rename atomically)
    NSURL* pdfURL = [NSURL fileURLWithPath:tmpPdfPath];
    CGContextRef pdfContext = CGPDFContextCreateWithURL((__bridge CFURLRef)pdfURL, NULL, NULL);
    if (!pdfContext)
    {
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    // Create pixel format
    unsigned int masks[4] = { 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000 };
    ddjvu_format_t* format = ddjvu_format_create(DDJVU_FORMAT_RGBMASK32, 4, masks);
    ddjvu_format_set_row_order(format, TRUE);
    ddjvu_format_set_y_direction(format, TRUE);

    BOOL success = YES;

    // Process pages sequentially
    for (int pageNum = 0; pageNum < pageCount && success; pageNum++)
    {
        @autoreleasepool
        {
            success = [self renderPage:pageNum fromDocument:doc withContext:ctx format:format toPdfContext:pdfContext];
        }
    }

    // Cleanup
    ddjvu_format_release(format);
    CGPDFContextClose(pdfContext);
    CGContextRelease(pdfContext);
    ddjvu_document_release(doc);
    ddjvu_context_release(ctx);

    if (success)
    {
        // Replace destination atomically to avoid ever exposing a partial PDF.
        [NSFileManager.defaultManager removeItemAtPath:pdfPath error:nil];
        if (![NSFileManager.defaultManager moveItemAtPath:tmpPdfPath toPath:pdfPath error:nil])
        {
            [NSFileManager.defaultManager removeItemAtPath:tmpPdfPath error:nil];
            return NO;
        }
        return YES;
    }

    // Failure: remove temp file
    [NSFileManager.defaultManager removeItemAtPath:tmpPdfPath error:nil];
    return NO;
}

/// Render a single page directly to PDF context
+ (BOOL)renderPage:(int)pageNum
      fromDocument:(ddjvu_document_t*)doc
       withContext:(ddjvu_context_t*)ctx
            format:(ddjvu_format_t*)format
      toPdfContext:(CGContextRef)pdfContext
{
    ddjvu_page_t* page = ddjvu_page_create_by_pageno(doc, pageNum);
    if (!page)
        return NO;

    // Wait for page to be decoded
    while (!ddjvu_page_decoding_done(page))
    {
        ddjvu_message_t* msg = ddjvu_message_wait(ctx);
        if (msg)
            ddjvu_message_pop(ctx);
    }

    if (ddjvu_page_decoding_error(page))
    {
        ddjvu_page_release(page);
        return NO;
    }

    ddjvu_page_type_t pageType = ddjvu_page_get_type(page);

    int pageWidth = ddjvu_page_get_width(page);
    int pageHeight = ddjvu_page_get_height(page);
    int pageDpi = ddjvu_page_get_resolution(page);

    if (pageWidth <= 0 || pageHeight <= 0 || pageDpi <= 0)
    {
        ddjvu_page_release(page);
        return NO;
    }

    // Render at up to 200 DPI (never upscale beyond the source DPI).
    // Upscaling increases PDF size without adding detail.
    int targetDpi = MIN(200, pageDpi);
    int renderWidth = (int)((double)pageWidth * targetDpi / pageDpi);
    int renderHeight = (int)((double)pageHeight * targetDpi / pageDpi);

    // Clamp to max 4000 pixels
    if (renderWidth > 4000 || renderHeight > 4000)
    {
        double scale = 4000.0 / MAX(renderWidth, renderHeight);
        renderWidth = (int)(renderWidth * scale);
        renderHeight = (int)(renderHeight * scale);
    }

    size_t rowSize = (size_t)renderWidth * 4;
    size_t bufferSize = rowSize * renderHeight;
    char* buffer = (char*)malloc(bufferSize);
    if (!buffer)
    {
        ddjvu_page_release(page);
        return NO;
    }

    // Fill with white background
    memset(buffer, 0xFF, bufferSize);

    // Render full page scaled to target size
    ddjvu_rect_t pageRect = { 0, 0, (unsigned int)renderWidth, (unsigned int)renderHeight };
    ddjvu_rect_t renderRect = { 0, 0, (unsigned int)renderWidth, (unsigned int)renderHeight };

    int rendered = ddjvu_page_render(page, DDJVU_RENDER_COLOR, &pageRect, &renderRect, format, rowSize, buffer);
    ddjvu_page_release(page);

    if (!rendered)
    {
        free(buffer);
        return NO;
    }

    // Encoding:
    // - Truly bitonal pages -> TIFF CCITT Group 4 (strict detection to avoid false positives)
    // - Other pages -> JPEG via TurboJPEG
    bool const bitonal = pageType != DDJVU_PAGETYPE_PHOTO && isTrulyBitonal((unsigned char const*)buffer, renderWidth, renderHeight, rowSize);

    CGImageRef image = nullptr;
    if (bitonal)
    {
        image = createTiffG4FromBitonal((unsigned char const*)buffer, renderWidth, renderHeight, rowSize);
    }
    else
    {
        int quality = pageType == DDJVU_PAGETYPE_PHOTO ? 80 : 85;
#if HAVE_TURBOJPEG
        int subsamp = TJSAMP_420;
#else
        int subsamp = 0;
#endif
        // If the page is grayscale, encode as grayscale JPEG (smaller than color JPEG).
        if (isGrayscale((unsigned char const*)buffer, renderWidth, renderHeight, rowSize))
        {
            size_t grayRowBytes = (size_t)renderWidth;
            size_t graySize = grayRowBytes * (size_t)renderHeight;
            auto* gray = (unsigned char*)malloc(graySize);
            if (gray != nullptr)
            {
                for (int y = 0; y < renderHeight; ++y)
                {
                    auto const* srcRow = (unsigned char const*)buffer + (size_t)y * rowSize;
                    auto* dstRow = gray + (size_t)y * grayRowBytes;
                    for (int x = 0; x < renderWidth; ++x)
                    {
                        dstRow[x] = srcRow[x * 4 + 2]; // r
                    }
                }

                image = createJpegFromGray(gray, renderWidth, renderHeight, grayRowBytes, quality);
                free(gray);
            }
        }

        if (image == nullptr)
        {
            image = createJpegFromBgra((unsigned char const*)buffer, renderWidth, renderHeight, rowSize, quality, subsamp);
        }
    }

    // Fallback: keep page readable even if compression fails
    if (!image)
    {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmapContext = CGBitmapContextCreate(
            buffer,
            renderWidth,
            renderHeight,
            8,
            rowSize,
            colorSpace,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

        if (bitmapContext)
        {
            image = CGBitmapContextCreateImage(bitmapContext);
            CGContextRelease(bitmapContext);
        }
        CGColorSpaceRelease(colorSpace);
    }

    free(buffer);

    if (!image)
        return NO;

    // Calculate PDF page size from original page dimensions
    CGFloat pdfWidth = (CGFloat)pageWidth * 72.0 / pageDpi;
    CGFloat pdfHeight = (CGFloat)pageHeight * 72.0 / pageDpi;
    CGRect mediaBox = CGRectMake(0, 0, pdfWidth, pdfHeight);

    // Draw to PDF
    NSData* mediaBoxData = [NSData dataWithBytes:&mediaBox length:sizeof(mediaBox)];
    NSDictionary* pageInfo = @{ (__bridge NSString*)kCGPDFContextMediaBox : mediaBoxData };
    CGPDFContextBeginPage(pdfContext, (__bridge CFDictionaryRef)pageInfo);
    CGContextDrawImage(pdfContext, mediaBox, image);
    CGPDFContextEndPage(pdfContext);

    CGImageRelease(image);
    return YES;
}

@end
