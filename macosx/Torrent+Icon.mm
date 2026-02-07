// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
                    if (self.fMediaType == TorrentMediaTypeAudio && [self isFileBasedAudioCueBased])
                    {
                        if (@available(macOS 11.0, *))
                        {
                            baseIcon = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:nil];
                            if (baseIcon)
                                [baseIcon setTemplate:YES];
                        }
                    }
                    if (!baseIcon)
                    {
                        UTType* contentType = [UTType typeWithFilenameExtension:self.fMediaExtension];
                        baseIcon = contentType ? [NSWorkspace.sharedWorkspace iconForContentType:contentType] : nil;
                        if (!baseIcon)
                        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                            baseIcon = [NSWorkspace.sharedWorkspace iconForFileType:self.fMediaExtension];
#pragma clang diagnostic pop
                        }
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
            NSString* ext = self.name.pathExtension.lowercaseString;
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
                UTType* contentType = [UTType typeWithFilenameExtension:ext];
                baseIcon = contentType ? [NSWorkspace.sharedWorkspace iconForContentType:contentType] : nil;
                if (!baseIcon)
                {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    baseIcon = [NSWorkspace.sharedWorkspace iconForFileType:ext];
#pragma clang diagnostic pop
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
