// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static NSImage* pdfTypeIcon(void);
static NSImage* iconForBookExtension(NSString* ext);
static NSImage* iconForBookPathOrExtension(NSString* path, NSString* ext, BOOL isComplete);
static NSString* bookPathWithExtension(Torrent* torrent, NSString* wantedExt);
static NSString* preferredBookPath(Torrent* torrent, NSString** outExt);

static NSImage* pdfTypeIcon(void)
{
    static NSImage* icon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        icon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypePDF];
        if (!icon)
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            icon = [NSWorkspace.sharedWorkspace iconForFileType:@"pdf"];
#pragma clang diagnostic pop
        }
    });
    return icon;
}

static NSImage* iconForBookExtension(NSString* ext)
{
    NSString* lowerExt = ext.lowercaseString;
    if (lowerExt.length == 0)
        return pdfTypeIcon();

    static NSSet<NSString*>* pdfFallbackExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pdfFallbackExtensions = [NSSet setWithArray:@[ @"djvu", @"djv", @"fb2", @"mobi" ]];
    });

    if ([pdfFallbackExtensions containsObject:lowerExt])
        return pdfTypeIcon();

    UTType* contentType = [UTType typeWithFilenameExtension:lowerExt];
    NSImage* icon = contentType ? [NSWorkspace.sharedWorkspace iconForContentType:contentType] : nil;
    if (!icon)
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        icon = [NSWorkspace.sharedWorkspace iconForFileType:lowerExt];
#pragma clang diagnostic pop
    }
    return icon ?: pdfTypeIcon();
}

static NSImage* iconForBookPathOrExtension(NSString* path, NSString* ext, BOOL isComplete)
{
    NSString* lowerExt = ext.lowercaseString;
    static NSSet<NSString*>* pdfFallbackExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pdfFallbackExtensions = [NSSet setWithArray:@[ @"djvu", @"djv", @"fb2", @"mobi" ]];
    });

    if ([pdfFallbackExtensions containsObject:lowerExt])
        return iconForBookExtension(lowerExt);

    if (isComplete && path.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:path])
    {
        NSImage* fileIcon = [NSWorkspace.sharedWorkspace iconForFile:path];
        if (fileIcon != nil)
            return fileIcon;
    }
    return iconForBookExtension(lowerExt);
}

static NSString* bookPathWithExtension(Torrent* torrent, NSString* wantedExt)
{
    NSUInteger const count = torrent.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(torrent.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        if (![fileName.pathExtension.lowercaseString isEqualToString:wantedExt])
            continue;

        auto const location = tr_torrentFindFile(torrent.fHandle, i);
        if (!std::empty(location))
            return @(location.c_str());
        return [torrent.currentDirectory stringByAppendingPathComponent:fileName];
    }
    return nil;
}

static NSString* preferredBookPath(Torrent* torrent, NSString** outExt)
{
    NSString* ext = @"epub";
    NSString* path = bookPathWithExtension(torrent, ext);
    if (path != nil)
    {
        if (outExt)
            *outExt = ext;
        return path;
    }

    ext = @"pdf";
    path = bookPathWithExtension(torrent, ext);
    if (path != nil)
    {
        if (outExt)
            *outExt = ext;
        return path;
    }

    static NSSet<NSString*>* bookExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
    });

    NSUInteger const count = torrent.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(torrent.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        NSString* fileExt = fileName.pathExtension.lowercaseString;
        if (![bookExtensions containsObject:fileExt])
            continue;

        if (outExt)
            *outExt = fileExt;

        auto const location = tr_torrentFindFile(torrent.fHandle, i);
        if (!std::empty(location))
            return @(location.c_str());
        return [torrent.currentDirectory stringByAppendingPathComponent:fileName];
    }
    return nil;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (Books)

- (NSString*)preferredBookPathOutExt:(NSString**)outExt
{
    return preferredBookPath(self, outExt);
}

- (NSImage*)iconForBookAtPath:(NSString*)path extension:(NSString*)ext isComplete:(BOOL)complete
{
    return iconForBookPathOrExtension(path, ext ?: @"pdf", complete);
}

@end
#pragma clang diagnostic pop
