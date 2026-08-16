// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Play menu and icon/title helpers for playable items. Keeps TorrentTableView under line limit.

#import "CocoaCompatibility.h"
#import "NSStringAdditions.h"
#import "PlayButtonStateBuilder.h"
#import "Torrent.h"
#import "TorrentPrivate.h"
#import "TorrentTableView.h"
#import "TorrentTableViewPrivate.h"
#include <libtransmission/transmission.h>

@implementation TorrentTableView (PlayMenu)

- (BOOL)isCueAlbumFileItem:(NSDictionary*)fileItem torrent:(Torrent*)torrent
{
    if (torrent)
        return [torrent playableItemOpensAsCueAlbum:fileItem];
    NSString* path = [fileItem[@"path"] isKindOfClass:[NSString class]] ? fileItem[@"path"] : nil;
    if (path.length > 0 && [path.pathExtension.lowercaseString isEqualToString:@"cue"])
        return YES;
    NSString* origExt = [fileItem[@"originalExt"] isKindOfClass:[NSString class]] ? [fileItem[@"originalExt"] lowercaseString] : nil;
    return [origExt isEqualToString:@"cue"];
}

- (NSImage*)iconForPlayableFileItem:(NSDictionary*)fileItem torrent:(Torrent*)torrent
{
    if (@available(macOS 11.0, *))
    {
        NSString* type = fileItem[@"type"] ?: @"file";
        NSString* category = fileItem[@"category"];
        BOOL const isCueFile = [self isCueAlbumFileItem:fileItem torrent:torrent];
        NSNumber* trackCountNum = fileItem[@"trackCount"];
        BOOL singleTrackAlbum = [type isEqualToString:@"album"] && !isCueFile && trackCountNum != nil &&
            trackCountNum.unsignedIntegerValue == 1;
        NSUInteger audioCount = 0, cueCount = 0;
        if (torrent)
            [torrent audioAndCueCount:&audioCount cueCount:&cueCount];
        BOOL useAlbumsIcon = isCueFile || [type isEqualToString:@"album"] ||
            ([type isEqualToString:@"file"] && [category isEqualToString:@"audio"] && audioCount <= cueCount);
        NSString* cacheKey = [NSString stringWithFormat:@"%@:%@:%d:%d", type, category ?: @"", singleTrackAlbum ? 1 : 0,
            useAlbumsIcon ? 1 : 0];
        NSImage* cached = [self.fIconCache objectForKey:cacheKey];
        if (cached)
            return cached;

        NSString* symbolName = @"play";
        if ([type isEqualToString:@"document-books"] || [category isEqualToString:@"books"])
            symbolName = @"book";
        else if (singleTrackAlbum)
            symbolName = @"music.note";
        else if (useAlbumsIcon)
            symbolName = @"music.note.list";
        else if ([type isEqualToString:@"track"] || [category isEqualToString:@"audio"])
            symbolName = @"music.note";
        else if ([type isEqualToString:@"dvd"] || [type isEqualToString:@"bluray"] || [category isEqualToString:@"video"])
            symbolName = @"play";
        else if ([category isEqualToString:@"software"])
            symbolName = @"gearshape";

        NSImage* icon = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        if (!icon)
            icon = [NSImage imageWithSystemSymbolName:@"play" accessibilityDescription:nil];
        if (icon)
        {
            NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium
                                                                                                  scale:NSImageSymbolScaleSmall];
            icon = [icon imageWithSymbolConfiguration:config];
            [icon setTemplate:YES];
            [self.fIconCache setObject:icon forKey:cacheKey];
        }
        return icon;
    }
    return nil;
}

- (NSMutableArray<NSDictionary*>*)visibleTracksForFolder:(NSString*)folder torrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* tracks = [torrent tracksForFolder:folder];
    if (tracks.count == 0)
        return nil;

    NSMutableArray<NSDictionary*>* visible = [NSMutableArray arrayWithCapacity:tracks.count];
    for (NSDictionary* track in tracks)
    {
        NSNumber* indexNum = track[@"index"];
        if (!indexNum)
            continue;
        tr_file_index_t const idx = (tr_file_index_t)indexNum.unsignedIntegerValue;
        auto const file = tr_torrentFile(torrent.torrentStruct, idx);
        CGFloat progress = (CGFloat)tr_torrentFileConsecutiveProgress(torrent.torrentStruct, idx);
        if (progress < 0)
            progress = 0;
        if (!file.wanted && progress < 1.0)
            continue;

        NSMutableDictionary* entry = [track mutableCopy];
        entry[@"progress"] = @(progress);
        [visible addObject:entry];
    }
    return visible.count > 0 ? visible : nil;
}

/// Single source for playable item display title. Prefers state title (stripped when 2+ items); otherwise displayNameForPlayableItem. Used by content buttons and context menu.
- (NSString*)menuTitleForPlayableItem:(NSDictionary*)item torrent:(Torrent*)torrent includeProgress:(BOOL)includeProgress
{
    NSString* base = (item[@"title"] && [item[@"title"] length] > 0) ? item[@"title"] : nil;
    if (base.length == 0)
        base = (item[@"name"] && [item[@"name"] length] > 0) ? item[@"name"] : nil;
    if (base.length == 0)
        base = [torrent displayNameForPlayableItem:item];
    if (!includeProgress || base.length == 0)
        return base;
    if (item[@"title"] && [item[@"title"] length] > 0)
        return base; // state title already includes progress when needed
    CGFloat progress = [item[@"progress"] doubleValue];
    if (progress <= 0 || progress >= 1.0)
        return base;
    int pct = (int)floor(progress * 100);
    return pct < 100 ? [NSString stringWithFormat:@"%@ (%d%%)", base, pct] : base;
}

- (NSMenu*)playMenuForTorrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
        return nil;

    NSMenu* cachedMenu = [self.fPlayMenuCache objectForKey:torrent];
    if (cachedMenu && torrent.content.cachedPlayMenuLayout != nil &&
        torrent.content.cachedPlayButtonLayout == torrent.content.cachedPlayMenuLayout)
        return cachedMenu;

    NSArray<NSDictionary*>* state = [PlayButtonStateBuilder stateForTorrent:torrent];
    NSArray<NSDictionary*>* layout = [PlayButtonStateBuilder layoutForTorrent:torrent state:state];
    if (layout.count == 0)
        return nil;

    if (cachedMenu && torrent.content.cachedPlayMenuLayout == layout)
        return cachedMenu;

    BOOL const isBooks = [torrent.detectedMediaCategory isEqualToString:@"books"];
    NSString* mainTitle = isBooks ? NSLocalizedString(@"Read", "Context menu") : NSLocalizedString(@"Play", "Context menu");
    NSMenu* menu = [[NSMenu alloc] initWithTitle:mainTitle];
    menu.delegate = self;

    NSMenuItem* pendingHeaderItem = nil;
    NSMenu* currentMenu = menu;
    for (NSDictionary* entry in layout)
    {
        NSString* kind = entry[@"kind"];
        if ([kind isEqualToString:@"header"])
        {
            NSString* title = entry[@"title"];
            if ([title hasSuffix:@":"])
                title = [title substringToIndex:title.length - 1];
            pendingHeaderItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
            NSMenu* seasonMenu = [[NSMenu alloc] initWithTitle:title];
            seasonMenu.delegate = self;
            pendingHeaderItem.submenu = seasonMenu;
            currentMenu = seasonMenu;
        }
        else
        {
            NSDictionary* fileItem = entry[@"item"];
            if (![fileItem[@"visible"] boolValue])
                continue;
            if (pendingHeaderItem)
            {
                [menu addItem:pendingHeaderItem];
                pendingHeaderItem = nil;
            }
            NSString* type = fileItem[@"type"] ?: @"file";
            NSString* menuTitle = [self menuTitleForPlayableItem:fileItem torrent:torrent includeProgress:YES];
            if ([type isEqualToString:@"album"])
            {
                NSString* folder = fileItem[@"folder"];
                NSMutableArray<NSDictionary*>* tracks = folder.length > 0 ? [self visibleTracksForFolder:folder torrent:torrent] : nil;
                if (tracks.count == 1)
                {
                    NSDictionary* track = tracks.firstObject;
                    menuTitle = [self menuTitleForPlayableItem:track torrent:torrent includeProgress:YES];
                    fileItem = track;
                }
                else if (tracks.count > 1)
                {
                    NSMutableDictionary* albumItemInfo = [fileItem mutableCopy];
                    albumItemInfo[@"trackCount"] = @(tracks.count);
                    NSMenuItem* albumItem = [[NSMenuItem alloc] initWithTitle:menuTitle action:nil keyEquivalent:@""];
                    albumItem.image = [self iconForPlayableFileItem:albumItemInfo torrent:torrent];
                    NSMenu* albumMenu = [[NSMenu alloc] initWithTitle:menuTitle];
                    albumMenu.delegate = self;
                    albumItem.submenu = albumMenu;
                    NSMutableArray<NSString*>* rawBases = [NSMutableArray arrayWithCapacity:tracks.count];
                    for (NSDictionary* track in tracks)
                        [rawBases addObject:[self menuTitleForPlayableItem:track torrent:torrent includeProgress:NO]];
                    NSArray<NSString*>* displayBases = (rawBases.count >= 2) ?
                        [Torrent displayTitlesByStrippingCommonPrefixSuffix:rawBases] :
                        rawBases;
                    NSUInteger trackIdx = 0;
                    for (NSDictionary* track in tracks)
                    {
                        NSString* base = displayBases[trackIdx++];
                        CGFloat progress = [track[@"progress"] doubleValue];
                        int pct = (int)floor(progress * 100);
                        NSString* trackTitle = (progress > 0 && progress < 1.0 && pct < 100) ?
                            [NSString stringWithFormat:@"%@ (%d%%)", base, pct] :
                            base;
                        NSMenuItem* trackItem = [[NSMenuItem alloc] initWithTitle:trackTitle action:@selector(playContextItem:)
                                                                    keyEquivalent:@""];
                        trackItem.target = self;
                        trackItem.representedObject = @{ @"torrent" : torrent, @"item" : track };
                        [albumMenu addItem:trackItem];
                    }
                    [currentMenu addItem:albumItem];
                    continue;
                }
            }
            NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle:menuTitle action:@selector(playContextItem:) keyEquivalent:@""];
            menuItem.target = self;
            menuItem.representedObject = @{ @"torrent" : torrent, @"item" : fileItem };
            menuItem.image = [self iconForPlayableFileItem:fileItem torrent:torrent];
            [currentMenu addItem:menuItem];
        }
    }
    if (menu.numberOfItems == 0)
        return nil;
    [self.fPlayMenuCache setObject:menu forKey:torrent];
    torrent.content.cachedPlayMenuLayout = layout;
    return menu;
}

- (void)updatePlayMenuForItem:(id)item
{
    NSArray* items = [self.fContextRow.itemArray copy];
    for (NSMenuItem* existing in items)
    {
        if (existing.tag == 100)
            [self.fContextRow removeItem:existing];
    }
    if (![item isKindOfClass:[Torrent class]])
        return;
    Torrent* torrent = (Torrent*)item;
    NSMenu* playMenu = [self playMenuForTorrent:torrent];
    if (!playMenu)
        return;
    BOOL const isAudio = [torrent.detectedMediaCategory isEqualToString:@"audio"];
    BOOL const isBooks = [torrent.detectedMediaCategory isEqualToString:@"books"];
    BOOL const isSoftware = [torrent.detectedMediaCategory isEqualToString:@"software"];
    NSImage* icon = nil;
    if (@available(macOS 11.0, *))
    {
        BOOL leadsToCue = NO;
        if (playMenu.numberOfItems > 0)
        {
            NSMenuItem* firstItem = playMenu.itemArray[0];
            NSDictionary* itemInfo = firstItem.representedObject;
            if ([itemInfo isKindOfClass:[NSDictionary class]])
            {
                NSDictionary* firstFileItem = itemInfo[@"item"];
                leadsToCue = firstFileItem ? [self isCueAlbumFileItem:firstFileItem torrent:torrent] : NO;
            }
        }
        NSString* symbol = isBooks ? @"book" : (isSoftware ? @"gearshape" : ((isAudio || leadsToCue) ? @"music.note.list" : @"play"));
        icon = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    }
    if (playMenu.numberOfItems == 1 && !playMenu.itemArray[0].hasSubmenu)
    {
        NSMenuItem* playItem = [playMenu.itemArray[0] copy];
        playItem.image = icon;
        playItem.tag = 100;
        [self.fContextRow insertItem:playItem atIndex:0];
    }
    else
    {
        NSMenuItem* mainItem = [[NSMenuItem alloc] initWithTitle:playMenu.title action:nil keyEquivalent:@""];
        mainItem.submenu = playMenu;
        mainItem.image = icon;
        mainItem.tag = 100;
        [self.fContextRow insertItem:mainItem atIndex:0];
    }
    NSMenuItem* sep = [NSMenuItem separatorItem];
    sep.tag = 100;
    [self.fContextRow insertItem:sep atIndex:1];
}

@end
