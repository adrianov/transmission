// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.
// Created by Mitchell Livingston on 1/10/14.

@import AppKit;

#import "ShareTorrentFileHelper.h"
#import "Controller.h"
#import "Torrent.h"

@implementation ShareTorrentFileHelper

+ (ShareTorrentFileHelper*)sharedHelper
{
    static ShareTorrentFileHelper* helper;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        helper = [[ShareTorrentFileHelper alloc] init];
    });
    return helper;
}

- (NSArray<NSURL*>*)shareTorrentURLs
{
    NSArray* torrents = ((Controller*)NSApp.delegate).selectedTorrents;
    NSMutableArray* fileURLs = [NSMutableArray arrayWithCapacity:torrents.count];
    for (Torrent* torrent in torrents)
    {
        NSString* location = torrent.torrentLocation;
        if (location.length > 0)
        {
            [fileURLs addObject:[NSURL fileURLWithPath:location]];
        }
    }
    return fileURLs;
}

- (NSArray<NSMenuItem*>*)menuItems
{
    if (@available(macOS 13.0, *))
    {
        NSSharingServicePicker* picker = [[NSSharingServicePicker alloc] initWithItems:self.shareTorrentURLs];
        picker.delegate = (Controller*)NSApp.delegate;
        NSMenuItem* shareMenuItem = [picker standardShareMenuItem];
        if (shareMenuItem)
        {
            return @[ shareMenuItem ];
        }
    }

// Fallback for older macOS versions (deprecated API, but needed for compatibility)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* services = [NSSharingService sharingServicesForItems:self.shareTorrentURLs];
#pragma clang diagnostic pop
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:services.count];
    for (NSSharingService* service in services)
    {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:service.title action:@selector(performShareAction:) keyEquivalent:@""];
        item.image = service.image;
        item.representedObject = service;
        service.delegate = (Controller*)NSApp.delegate;
        item.target = self;
        [items addObject:item];
    }

    return items;
}

- (void)performShareAction:(NSMenuItem*)item
{
    NSSharingService* service = item.representedObject;
    [service performWithItems:self.shareTorrentURLs];
}

@end
