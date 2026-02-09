// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (Icon)

/// Adds a subtle drop shadow to an icon image for better visibility.
+ (NSImage*)iconWithShadow:(NSImage*)icon
{
    NSSize size = icon.size;
    if (size.width <= 0 || size.height <= 0)
        return icon;

    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [NSGraphicsContext saveGraphicsState];

        NSShadow* shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
        shadow.shadowOffset = NSMakeSize(0, -1);
        shadow.shadowBlurRadius = 2.0;
        [shadow set];

        CGFloat const inset = 2.0;
        NSRect contentRect = NSMakeRect(inset, inset + 1, dstRect.size.width - inset * 2, dstRect.size.height - inset * 2);
        [icon drawInRect:contentRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];

        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }];
}

- (NSImage*)icon
{
    if (self.magnet)
        return [NSImage imageNamed:@"Magnet"];

    if (!self.fIcon)
    {
        NSImage* baseIcon;
        if (self.folder)
        {
            [self detectMediaType];
            if (self.fMediaType != TorrentMediaTypeNone && self.fMediaExtension)
            {
                if (self.fMediaType == TorrentMediaTypeBooks)
                {
                    NSString* bookExt = nil;
                    NSString* bookPath = [self preferredBookPathOutExt:&bookExt];
                    baseIcon = [self iconForBookAtPath:bookPath extension:bookExt isComplete:self.allDownloaded];
                }
                else
                {
                    // Regression: do not use SF Symbols (e.g. music.note.list) here. The transfer list left icon
                    // must be a Finder-style file-type icon (mp3, flac, etc.). Use iconForFileType: first;
                    // iconForContentType: returns SF Symbol–style icons on recent macOS.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    baseIcon = [NSWorkspace.sharedWorkspace iconForFileType:self.fMediaExtension];
#pragma clang diagnostic pop
                    if (!baseIcon)
                    {
                        UTType* contentType = [UTType typeWithFilenameExtension:self.fMediaExtension];
                        baseIcon = [NSWorkspace.sharedWorkspace iconForContentType:contentType];
                    }
                }
            }
            else
            {
                baseIcon = [NSImage imageNamed:NSImageNameFolder];
            }
        }
        else
        {
            NSArray<NSDictionary*>* playable = self.playableFiles;
            BOOL singleAlbum = playable.count == 1 && [self playableItemOpensAsCueAlbum:playable.firstObject];
            NSString* ext = self.name.pathExtension.lowercaseString;
            if (singleAlbum && playable.count > 0)
            {
                NSDictionary* item = playable.firstObject;
                id pathObj = item[@"path"];
                NSString* itemExt = [pathObj isKindOfClass:[NSString class]] && [(NSString*)pathObj length] > 0
                    ? [(NSString*)pathObj pathExtension].lowercaseString
                    : nil;
                if (itemExt.length == 0)
                    itemExt = [item[@"originalExt"] isKindOfClass:[NSString class]] ? [item[@"originalExt"] lowercaseString] : nil;
                if ([itemExt isEqualToString:@"cue"])
                {
                    NSString* cuePath = playable.firstObject[@"path"];
                    if ([cuePath isKindOfClass:[NSString class]] && ((NSString*)cuePath).length > 0)
                    {
                        for (NSUInteger i = 0; i < self.fileCount; i++)
                        {
                            auto const file = tr_torrentFile(self.fHandle, i);
                            NSString* fileName = [NSString convertedStringFromCString:file.name];
                            if (fileName.length == 0)
                                continue;
                            NSString* filePath = [self.currentDirectory stringByAppendingPathComponent:fileName];
                            NSString* resolvedCue = [self cueFilePathForAudioPath:filePath];
                            if (resolvedCue != nil && [resolvedCue isEqualToString:cuePath])
                            {
                                ext = fileName.pathExtension.lowercaseString;
                                break;
                            }
                        }
                    }
                }
                else if (itemExt.length > 0)
                    ext = itemExt;
            }
            static NSSet<NSString*>* bookExtensions;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
            });
            if (ext.length > 0 && [bookExtensions containsObject:ext])
            {
                auto const location = tr_torrentFindFile(self.fHandle, 0);
                NSString* filePath = !std::empty(location) ? @(location.c_str()) :
                                                             [self.currentDirectory stringByAppendingPathComponent:self.name];
                baseIcon = [self iconForBookAtPath:filePath extension:ext isComplete:self.allDownloaded];
            }
            else
            {
                // Same as folder case: use iconForFileType for Finder-style icon, not SF Symbol.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                baseIcon = (ext.length > 0) ? [NSWorkspace.sharedWorkspace iconForFileType:ext] : nil;
#pragma clang diagnostic pop
                if (!baseIcon && ext.length > 0)
                {
                    UTType* contentType = [UTType typeWithFilenameExtension:ext];
                    baseIcon = [NSWorkspace.sharedWorkspace iconForContentType:contentType];
                }
            }
        }

        if (!baseIcon)
            baseIcon = [NSImage imageNamed:NSImageNameMultipleDocuments];

        self.fIcon = [Torrent iconWithShadow:baseIcon];
    }
    return self.fIcon;
}

@end
#pragma clang diagnostic pop
