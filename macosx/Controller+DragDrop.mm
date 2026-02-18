// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Window drag-and-drop: accept torrent files and URLs. Keeps drag/drop logic out of main Controller.

#include <libtransmission/torrent-metainfo.h>

#import "ControllerPrivate.h"
#import "CocoaCompatibility.h"
#import "CreatorWindowController.h"
#import "DragOverlayWindow.h"
#import "Torrent.h"

@implementation Controller (DragDrop)

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    NSPasteboard* pasteboard = info.draggingPasteboard;
    if ([pasteboard.types containsObject:NSPasteboardTypeFileURL])
    {
        BOOL torrent = NO;
        NSArray<NSURL*>* files = [pasteboard readObjectsForClasses:@[ NSURL.class ]
                                                           options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
        for (NSURL* fileToParse in files)
        {
            NSString* contentType = nil;
            [fileToParse getResourceValue:&contentType forKey:NSURLContentTypeKey error:NULL];
            if ([contentType isEqualToString:@"org.bittorrent.torrent"] ||
                [fileToParse.pathExtension caseInsensitiveCompare:@"torrent"] == NSOrderedSame)
            {
                torrent = YES;
                auto metainfo = tr_torrent_metainfo{};
                if (metainfo.parse_torrent_file(fileToParse.path.UTF8String))
                {
                    if (!self.fOverlayWindow)
                    {
                        self.fOverlayWindow = [[DragOverlayWindow alloc] initForWindow:self.fWindow];
                    }
                    NSMutableArray<NSString*>* filesToOpen = [NSMutableArray arrayWithCapacity:files.count];
                    for (NSURL* fileToOpen in files)
                    {
                        [filesToOpen addObject:fileToOpen.path];
                    }
                    [self.fOverlayWindow setTorrents:filesToOpen];

                    return NSDragOperationCopy;
                }
            }
        }

        if (!torrent && files.count == 1)
        {
            if (!self.fOverlayWindow)
            {
                self.fOverlayWindow = [[DragOverlayWindow alloc] initForWindow:self.fWindow];
            }
            [self.fOverlayWindow setFile:[files[0] lastPathComponent]];

            return NSDragOperationCopy;
        }
    }
    else if ([pasteboard.types containsObject:NSPasteboardTypeURL])
    {
        if (!self.fOverlayWindow)
        {
            self.fOverlayWindow = [[DragOverlayWindow alloc] initForWindow:self.fWindow];
        }
        [self.fOverlayWindow setURL:[NSURL URLFromPasteboard:pasteboard].relativeString];

        return NSDragOperationCopy;
    }

    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)info
{
    if (self.fOverlayWindow)
    {
        [self.fOverlayWindow fadeOut];
    }
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    if (self.fOverlayWindow)
    {
        [self.fOverlayWindow fadeOut];
    }

    NSPasteboard* pasteboard = info.draggingPasteboard;
    if ([pasteboard.types containsObject:NSPasteboardTypeFileURL])
    {
        BOOL torrent = NO, accept = YES;

        NSArray<NSURL*>* files = [pasteboard readObjectsForClasses:@[ NSURL.class ]
                                                           options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
        NSMutableArray<NSString*>* filesToOpen = [NSMutableArray arrayWithCapacity:files.count];
        for (NSURL* file in files)
        {
            NSString* contentType = nil;
            [file getResourceValue:&contentType forKey:NSURLContentTypeKey error:NULL];
            if ([contentType isEqualToString:@"org.bittorrent.torrent"] || [file.pathExtension caseInsensitiveCompare:@"torrent"] == NSOrderedSame)
            {
                torrent = YES;
                auto metainfo = tr_torrent_metainfo{};
                if (metainfo.parse_torrent_file(file.path.UTF8String))
                {
                    [filesToOpen addObject:file.path];
                }
            }
        }

        if (filesToOpen.count > 0)
        {
            [self application:NSApp openFiles:filesToOpen];
        }
        else
        {
            if (!torrent && files.count == 1)
            {
                [CreatorWindowController createTorrentFile:self.fLib forFile:files[0]];
            }
            else
            {
                accept = NO;
            }
        }

        return accept;
    }
    else if ([pasteboard.types containsObject:NSPasteboardTypeURL])
    {
        NSURL* url;
        if ((url = [NSURL URLFromPasteboard:pasteboard]))
        {
            [self openURL:url.absoluteString];
            return YES;
        }
    }

    return NO;
}

@end
