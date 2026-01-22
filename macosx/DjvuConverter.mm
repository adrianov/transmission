// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "DjvuConverter.h"
#import "Torrent.h"
#import "FileListNode.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Quartz/Quartz.h>
#import <ddjvuapi.h>

// Track files that have been queued for conversion (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sConversionQueue = nil;
static dispatch_queue_t sConversionDispatchQueue = nil;

/// Check if PDF file is valid by verifying it can be opened and pages can be read
static BOOL isValidPdf(NSString* path)
{
    // Use PDFKit which does more thorough validation (same as Preview)
    NSURL* url = [NSURL fileURLWithPath:path];
    PDFDocument* pdf = [[PDFDocument alloc] initWithURL:url];
    if (!pdf)
        return NO;

    NSUInteger pageCount = pdf.pageCount;
    if (pageCount == 0)
        return NO;

    // Try to access first page to verify content is readable
    PDFPage* firstPage = [pdf pageAtIndex:0];
    if (!firstPage)
        return NO;

    // Check if page has valid bounds
    NSRect bounds = [firstPage boundsForBox:kPDFDisplayBoxMediaBox];
    if (NSIsEmptyRect(bounds) || bounds.size.width <= 0 || bounds.size.height <= 0)
        return NO;

    return YES;
}

@implementation DjvuConverter

+ (void)initialize
{
    if (self == [DjvuConverter class])
    {
        sConversionQueue = [NSMutableDictionary dictionary];
        sConversionDispatchQueue = dispatch_queue_create("com.transmissionbt.djvuconverter", DISPATCH_QUEUE_SERIAL);
    }
}

+ (void)checkAndConvertCompletedFiles:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return;

    NSString* torrentHash = torrent.hashString;
    NSArray<FileListNode*>* fileList = torrent.flatFileList;

    // Get or create tracking set for this torrent
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];
    if (!queuedFiles)
    {
        queuedFiles = [NSMutableSet set];
        sConversionQueue[torrentHash] = queuedFiles;
    }

    NSMutableArray<NSDictionary*>* filesToConvert = [NSMutableArray array];

    for (FileListNode* node in fileList)
    {
        NSString* name = node.name;
        NSString* ext = name.pathExtension.lowercaseString;

        // Only process DJVU files
        if (![ext isEqualToString:@"djvu"] && ![ext isEqualToString:@"djv"])
            continue;

        // Check if file is 100% complete
        CGFloat progress = [torrent fileProgress:node];
        if (progress < 1.0)
            continue;

        NSString* path = [torrent fileLocation:node];
        if (!path)
            continue;

        NSString* pdfPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];

        // Check if PDF already exists
        if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
        {
            if (isValidPdf(pdfPath))
            {
                [queuedFiles addObject:path]; // Mark as done
                continue;
            }
            // Remove invalid/damaged PDF before conversion
            NSLog(@"Removing invalid PDF: %@", pdfPath);
            [NSFileManager.defaultManager removeItemAtPath:pdfPath error:nil];
            // Remove from queued so it will be reconverted
            [queuedFiles removeObject:path];
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

    // Run conversion on background queue
    dispatch_async(sConversionDispatchQueue, ^{
        BOOL anySuccess = NO;
        for (NSDictionary* file in filesToConvert)
        {
            NSString* djvuPath = file[@"djvu"];
            NSString* pdfPath = file[@"pdf"];

            // Double-check PDF doesn't exist and is valid (race condition protection)
            if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath] && isValidPdf(pdfPath))
                continue;

            BOOL success = [self convertDjvuFile:djvuPath toPdf:pdfPath];
            if (success)
            {
                NSLog(@"DJVU conversion successful: %@ -> %@", djvuPath.lastPathComponent, pdfPath.lastPathComponent);
                anySuccess = YES;
            }
            else
            {
                NSLog(@"DJVU conversion failed: %@", djvuPath.lastPathComponent);
            }
        }

        // Notify main thread to refresh playable files cache
        if (anySuccess)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:@"DjvuConversionComplete" object:torrentHash];
            });
        }
    });
}

+ (void)clearTrackingForTorrent:(Torrent*)torrent
{
    if (!torrent)
        return;

    [sConversionQueue removeObjectForKey:torrent.hashString];
}

+ (BOOL)isValidPdf:(NSString*)path
{
    return isValidPdf(path);
}

+ (BOOL)convertDjvuFile:(NSString*)djvuPath toPdf:(NSString*)pdfPath
{
    // Create DJVU context
    ddjvu_context_t* ctx = ddjvu_context_create("Transmission");
    if (!ctx)
    {
        NSLog(@"Failed to create DJVU context");
        return NO;
    }

    // Open DJVU document
    ddjvu_document_t* doc = ddjvu_document_create_by_filename_utf8(ctx, djvuPath.UTF8String, FALSE);
    if (!doc)
    {
        NSLog(@"Failed to open DJVU document: %@", djvuPath);
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

    // Check for errors
    if (ddjvu_document_decoding_error(doc))
    {
        NSLog(@"Error decoding DJVU document: %@", djvuPath);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    int pageCount = ddjvu_document_get_pagenum(doc);
    if (pageCount <= 0)
    {
        NSLog(@"DJVU document has no pages: %@", djvuPath);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    // Create PDF context
    NSURL* pdfURL = [NSURL fileURLWithPath:pdfPath];
    CGContextRef pdfContext = CGPDFContextCreateWithURL((__bridge CFURLRef)pdfURL, NULL, NULL);
    if (!pdfContext)
    {
        NSLog(@"Failed to create PDF context for: %@", pdfPath);
        ddjvu_document_release(doc);
        ddjvu_context_release(ctx);
        return NO;
    }

    // Create pixel format (BGRA for Core Graphics)
    unsigned int masks[4] = { 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000 }; // BGRA
    ddjvu_format_t* format = ddjvu_format_create(DDJVU_FORMAT_RGBMASK32, 4, masks);
    ddjvu_format_set_row_order(format, TRUE); // Top to bottom
    ddjvu_format_set_y_direction(format, TRUE);

    BOOL success = YES;

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

    // Delete partial PDF on failure
    if (!success)
    {
        [NSFileManager.defaultManager removeItemAtPath:pdfPath error:nil];
    }

    return success;
}

+ (BOOL)renderPage:(int)pageNum
      fromDocument:(ddjvu_document_t*)doc
       withContext:(ddjvu_context_t*)ctx
            format:(ddjvu_format_t*)format
      toPdfContext:(CGContextRef)pdfContext
{
    ddjvu_page_t* page = ddjvu_page_create_by_pageno(doc, pageNum);
    if (!page)
    {
        NSLog(@"Failed to create page %d", pageNum);
        return NO;
    }

    // Wait for page to be decoded
    while (!ddjvu_page_decoding_done(page))
    {
        ddjvu_message_t* msg = ddjvu_message_wait(ctx);
        if (msg)
            ddjvu_message_pop(ctx);
    }

    if (ddjvu_page_decoding_error(page))
    {
        NSLog(@"Error decoding page %d", pageNum);
        ddjvu_page_release(page);
        return NO;
    }

    // Get page dimensions at 150 DPI (good balance of quality and size)
    int dpi = 150;
    int pageWidth = ddjvu_page_get_width(page);
    int pageHeight = ddjvu_page_get_height(page);
    int pageDpi = ddjvu_page_get_resolution(page);

    if (pageWidth <= 0 || pageHeight <= 0 || pageDpi <= 0)
    {
        NSLog(@"Invalid page dimensions for page %d", pageNum);
        ddjvu_page_release(page);
        return NO;
    }

    // Scale to target DPI
    int renderWidth = (int)((double)pageWidth * dpi / pageDpi);
    int renderHeight = (int)((double)pageHeight * dpi / pageDpi);

    // Clamp to reasonable size (max 4000 pixels)
    if (renderWidth > 4000 || renderHeight > 4000)
    {
        double scale = 4000.0 / MAX(renderWidth, renderHeight);
        renderWidth = (int)(renderWidth * scale);
        renderHeight = (int)(renderHeight * scale);
    }

    // Allocate buffer
    size_t rowSize = (size_t)renderWidth * 4; // 4 bytes per pixel (BGRA)
    size_t bufferSize = rowSize * renderHeight;
    char* buffer = (char*)malloc(bufferSize);
    if (!buffer)
    {
        NSLog(@"Failed to allocate buffer for page %d", pageNum);
        ddjvu_page_release(page);
        return NO;
    }

    // Fill with white background
    memset(buffer, 0xFF, bufferSize);

    // Setup render rectangles
    ddjvu_rect_t pageRect = { 0, 0, (unsigned int)renderWidth, (unsigned int)renderHeight };
    ddjvu_rect_t renderRect = { 0, 0, (unsigned int)renderWidth, (unsigned int)renderHeight };

    // Render page
    int rendered = ddjvu_page_render(page, DDJVU_RENDER_COLOR, &pageRect, &renderRect, format, rowSize, buffer);

    if (!rendered)
    {
        NSLog(@"Failed to render page %d", pageNum);
        free(buffer);
        ddjvu_page_release(page);
        return NO;
    }

    // Create CGImage from buffer
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapContext = CGBitmapContextCreate(buffer, renderWidth, renderHeight, 8, rowSize, colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

    if (!bitmapContext)
    {
        NSLog(@"Failed to create bitmap context for page %d", pageNum);
        CGColorSpaceRelease(colorSpace);
        free(buffer);
        ddjvu_page_release(page);
        return NO;
    }

    CGImageRef image = CGBitmapContextCreateImage(bitmapContext);
    CGContextRelease(bitmapContext);
    CGColorSpaceRelease(colorSpace);
    free(buffer);

    if (!image)
    {
        NSLog(@"Failed to create image for page %d", pageNum);
        ddjvu_page_release(page);
        return NO;
    }

    // Calculate PDF page size in points (72 points per inch)
    CGFloat pdfWidth = (CGFloat)pageWidth * 72.0 / pageDpi;
    CGFloat pdfHeight = (CGFloat)pageHeight * 72.0 / pageDpi;
    CGRect mediaBox = CGRectMake(0, 0, pdfWidth, pdfHeight);

    // Draw to PDF
    CGPDFContextBeginPage(pdfContext, NULL);
    CGContextDrawImage(pdfContext, mediaBox, image);
    CGPDFContextEndPage(pdfContext);

    CGImageRelease(image);
    ddjvu_page_release(page);

    return YES;
}

@end
