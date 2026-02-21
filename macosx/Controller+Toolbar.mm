// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Toolbar item creation, validation, and Play Random Audio. NSToolbarDelegate and NSToolbarItemValidation.

#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "ButtonToolbarItem.h"
#import "FilterBarController.h"
#import "GroupToolbarItem.h"
#import "InfoWindowController.h"
#import "PlayButtonStateBuilder.h"
#import "ShareToolbarItem.h"
#import "Torrent.h"
#import "Toolbar.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (Toolbar)

- (ButtonToolbarItem*)standardToolbarButtonWithIdentifier:(NSString*)ident
{
    return [self toolbarButtonWithIdentifier:ident forToolbarButtonClass:[ButtonToolbarItem class]];
}

- (__kindof ButtonToolbarItem*)toolbarButtonWithIdentifier:(NSString*)ident forToolbarButtonClass:(Class)klass
{
    ButtonToolbarItem* item = [[klass alloc] initWithItemIdentifier:ident];

    NSButton* button = [[NSButton alloc] init];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.stringValue = @"";

    item.view = button;

    return item;
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSString*)ident willBeInsertedIntoToolbar:(BOOL)flag
{
    if ([ident isEqualToString:ToolbarItemIdentifierCreate])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];

        item.label = NSLocalizedString(@"Create", "Create toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Create Torrent File", "Create toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Create torrent file", "Create toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"doc.badge.plus" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(createFile:);
        item.autovalidates = NO;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierOpenFile])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];

        item.label = NSLocalizedString(@"Open", "Open toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Open Torrent Files", "Open toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Open torrent files", "Open toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(openShowSheet:);
        item.autovalidates = NO;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierOpenWeb])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];

        item.label = NSLocalizedString(@"Open Address", "Open address toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Open Torrent Address", "Open address toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Open torrent web address", "Open address toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(openURLShowSheet:);
        item.autovalidates = NO;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierRemove])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];

        item.label = NSLocalizedString(@"Remove", "Remove toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Remove Selected", "Remove toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Remove selected transfers", "Remove toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"nosign" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(removeNoDelete:);
        item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierRemoveTrash])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];

        item.label = NSLocalizedString(@"Delete", "Remove and delete toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Remove and Delete Selected", "Remove and delete toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Remove selected transfers and permanently delete data", "Remove and delete toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(removeDeleteData:);
        item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierInfo])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];
        ((NSButtonCell*)((NSButton*)item.view).cell).showsStateBy = NSContentsCellMask;

        item.label = NSLocalizedString(@"Inspector", "Inspector toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Toggle Inspector", "Inspector toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Toggle the torrent inspector", "Inspector toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(showInfo:);

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierPauseResumeAll])
    {
        GroupToolbarItem* groupItem = [[GroupToolbarItem alloc] initWithItemIdentifier:ident];

        NSToolbarItem* itemPause = [self standardToolbarButtonWithIdentifier:ToolbarItemIdentifierPauseAll];
        NSToolbarItem* itemResume = [self standardToolbarButtonWithIdentifier:ToolbarItemIdentifierResumeAll];

        NSSegmentedControl* segmentedControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
        segmentedControl.segmentStyle = NSSegmentStyleTexturedRounded;
        segmentedControl.trackingMode = NSSegmentSwitchTrackingMomentary;
        segmentedControl.segmentCount = 2;

        [segmentedControl setTag:ToolbarGroupTagPause forSegment:ToolbarGroupTagPause];
        [segmentedControl setImage:[NSImage imageWithSystemSymbolName:@"pause.circle.fill" accessibilityDescription:nil]
                        forSegment:ToolbarGroupTagPause];
        [segmentedControl setToolTip:NSLocalizedString(@"Pause all transfers", "All toolbar item -> tooltip")
                          forSegment:ToolbarGroupTagPause];

        [segmentedControl setTag:ToolbarGroupTagResume forSegment:ToolbarGroupTagResume];
        [segmentedControl setImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise.circle.fill" accessibilityDescription:nil]
                        forSegment:ToolbarGroupTagResume];
        [segmentedControl setToolTip:NSLocalizedString(@"Resume all transfers", "All toolbar item -> tooltip")
                          forSegment:ToolbarGroupTagResume];
        if ([toolbar isKindOfClass:Toolbar.class] && ((Toolbar*)toolbar).isRunningCustomizationPalette)
        {
            [segmentedControl setWidth:64 forSegment:ToolbarGroupTagPause];
            [segmentedControl setWidth:64 forSegment:ToolbarGroupTagResume];
        }

        groupItem.label = NSLocalizedString(@"Apply All", "All toolbar item -> label");
        groupItem.paletteLabel = NSLocalizedString(@"Pause / Resume All", "All toolbar item -> palette label");
        groupItem.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        groupItem.subitems = @[ itemPause, itemResume ];
        groupItem.view = segmentedControl;
        groupItem.target = self;
        groupItem.action = @selector(allToolbarClicked:);

        [groupItem createMenu:@[
            NSLocalizedString(@"Pause All", "All toolbar item -> label"),
            NSLocalizedString(@"Resume All", "All toolbar item -> label")
        ]];

        return groupItem;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierPauseResumeSelected])
    {
        GroupToolbarItem* groupItem = [[GroupToolbarItem alloc] initWithItemIdentifier:ident];

        NSToolbarItem* itemPause = [self standardToolbarButtonWithIdentifier:ToolbarItemIdentifierPauseSelected];
        NSToolbarItem* itemResume = [self standardToolbarButtonWithIdentifier:ToolbarItemIdentifierResumeSelected];

        NSSegmentedControl* segmentedControl = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
        segmentedControl.segmentStyle = NSSegmentStyleTexturedRounded;
        segmentedControl.trackingMode = NSSegmentSwitchTrackingMomentary;
        segmentedControl.segmentCount = 2;

        [segmentedControl setTag:ToolbarGroupTagPause forSegment:ToolbarGroupTagPause];
        [segmentedControl setImage:[NSImage imageWithSystemSymbolName:@"pause" accessibilityDescription:nil]
                        forSegment:ToolbarGroupTagPause];
        [segmentedControl setToolTip:NSLocalizedString(@"Pause selected transfers", "Selected toolbar item -> tooltip")
                          forSegment:ToolbarGroupTagPause];

        [segmentedControl setTag:ToolbarGroupTagResume forSegment:ToolbarGroupTagResume];
        [segmentedControl setImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:nil]
                        forSegment:ToolbarGroupTagResume];
        [segmentedControl setToolTip:NSLocalizedString(@"Resume selected transfers", "Selected toolbar item -> tooltip")
                          forSegment:ToolbarGroupTagResume];
        if ([toolbar isKindOfClass:Toolbar.class] && ((Toolbar*)toolbar).isRunningCustomizationPalette)
        {
            [segmentedControl setWidth:64 forSegment:ToolbarGroupTagPause];
            [segmentedControl setWidth:64 forSegment:ToolbarGroupTagResume];
        }

        groupItem.label = NSLocalizedString(@"Apply Selected", "Selected toolbar item -> label");
        groupItem.paletteLabel = NSLocalizedString(@"Pause / Resume Selected", "Selected toolbar item -> palette label");
        groupItem.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        groupItem.subitems = @[ itemPause, itemResume ];
        groupItem.view = segmentedControl;
        groupItem.target = self;
        groupItem.action = @selector(selectedToolbarClicked:);

        [groupItem createMenu:@[
            NSLocalizedString(@"Pause Selected", "Selected toolbar item -> label"),
            NSLocalizedString(@"Resume Selected", "Selected toolbar item -> label")
        ]];

        return groupItem;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierFilter])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];
        ((NSButtonCell*)((NSButton*)item.view).cell).showsStateBy = NSContentsCellMask;

        item.label = NSLocalizedString(@"Filter", "Filter toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Toggle Filter", "Filter toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Toggle the filter bar", "Filter toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(toggleFilterBar:);

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierQuickLook])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];
        ((NSButtonCell*)((NSButton*)item.view).cell).showsStateBy = NSContentsCellMask;

        item.label = NSLocalizedString(@"Quick Look", "QuickLook toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Quick Look", "QuickLook toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Quick Look", "QuickLook toolbar item -> tooltip");
        item.image = [NSImage imageNamed:NSImageNameQuickLookTemplate];
        item.target = self;
        item.action = @selector(toggleQuickLook:);
        item.visibilityPriority = NSToolbarItemVisibilityPriorityLow;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierShare])
    {
        ShareToolbarItem* item = [self toolbarButtonWithIdentifier:ident forToolbarButtonClass:[ShareToolbarItem class]];

        item.label = NSLocalizedString(@"Share", "Share toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Share", "Share toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Share torrent file", "Share toolbar item -> tooltip");
        item.image = [NSImage imageNamed:NSImageNameShareTemplate];
        item.visibilityPriority = NSToolbarItemVisibilityPriorityLow;

        NSButton* itemButton = (NSButton*)item.view;
        itemButton.target = self;
        itemButton.action = @selector(showToolbarShare:);
        [itemButton sendActionOn:NSEventMaskLeftMouseDown];

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierSearch])
    {
        NSSearchToolbarItem* item = [[NSSearchToolbarItem alloc] initWithItemIdentifier:ident];

        NSSearchField* searchField = item.searchField;
        searchField.placeholderString = NSLocalizedString(@"Press Enter to Search on the rutracker.org...", "Search toolbar item -> placeholder");
        searchField.delegate = self;
        self.fToolbarSearchField = searchField;
        [self updateSearchFieldClearButtonVisibility:searchField];

        item.label = NSLocalizedString(@"Search", "Search toolbar item -> label");
        item.preferredWidthForSearchField = 240;

        return item;
    }
    else if ([ident isEqualToString:ToolbarItemIdentifierPlayRandomAudio])
    {
        ButtonToolbarItem* item = [self standardToolbarButtonWithIdentifier:ident];
        item.label = NSLocalizedString(@"Play Random Audio", "Play Random Audio toolbar item -> label");
        item.paletteLabel = NSLocalizedString(@"Play Random Audio", "Play Random Audio toolbar item -> palette label");
        item.toolTip = NSLocalizedString(@"Play Random Audio", "Play Random Audio toolbar item -> tooltip");
        item.image = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:nil];
        item.target = self;
        item.action = @selector(playRandomAudio:);
        item.visibilityPriority = NSToolbarItemVisibilityPriorityLow;
        // Avoid main-thread autovalidation path scans during startup/login.
        item.autovalidates = NO;
        return item;
    }
    else
    {
        return nil;
    }
}

- (void)allToolbarClicked:(id)sender
{
    NSInteger tagValue = [sender isKindOfClass:[NSSegmentedControl class]] ? [(NSSegmentedControl*)sender selectedTag] :
                                                                             ((NSControl*)sender).tag;
    switch (tagValue)
    {
    case ToolbarGroupTagPause:
        [self stopAllTorrents:sender];
        break;
    case ToolbarGroupTagResume:
        [self resumeAllTorrents:sender];
        break;
    }
}

- (void)selectedToolbarClicked:(id)sender
{
    NSInteger tagValue = [sender isKindOfClass:[NSSegmentedControl class]] ? [(NSSegmentedControl*)sender selectedTag] :
                                                                             ((NSControl*)sender).tag;
    switch (tagValue)
    {
    case ToolbarGroupTagPause:
        [self stopSelectedTorrents:sender];
        break;
    case ToolbarGroupTagResume:
        [self resumeSelectedTorrents:sender];
        break;
    }
}

/// Candidates for Play Random Audio: visible audio items, with optional existing-path verification.
- (NSArray<NSArray*>*)transferredAudioCandidatesCheckingPathExistence:(BOOL)checkPathExistence
{
    NSMutableArray<NSArray*>* result = [NSMutableArray array];
    for (Torrent* torrent in self.fTorrents)
    {
        NSDictionary* snapshotDict = [PlayButtonStateBuilder buildSnapshotForTorrent:torrent];
        if (!snapshotDict)
            continue;
        NSArray* playableFiles = snapshotDict[@"playableFiles"];
        NSArray* snapshot = snapshotDict[@"snapshot"];
        NSDictionary* stateAndLayout = [PlayButtonStateBuilder stateAndLayoutFromSnapshot:snapshot];
        NSArray* state = stateAndLayout[@"state"];
        if (state.count != playableFiles.count)
            continue;
        for (NSUInteger i = 0; i < state.count; i++)
        {
            NSDictionary* entry = state[i];
            if (![entry[@"visible"] boolValue])
                continue;
            NSString* category = entry[@"category"] ?: @"";
            if (![category isEqualToString:@"audio"])
                continue;
            NSDictionary* item = playableFiles[i];
            if (checkPathExistence && ![torrent pathToOpenForPlayableItemIfExists:item])
                continue;
            [result addObject:@[ torrent, item ]];
        }
    }
    return result;
}

- (void)playRandomAudio:(id)sender
{
    NSArray<NSArray*>* candidates = [self transferredAudioCandidatesCheckingPathExistence:YES];
    if (candidates.count == 0)
        return;
    NSMutableArray<NSArray*>* zeroPlays = [NSMutableArray array];
    for (NSArray* pair in candidates)
    {
        Torrent* torrent = pair[0];
        NSDictionary* item = pair[1];
        if ([torrent openCountForPlayableItem:item] == 0)
            [zeroPlays addObject:pair];
    }
    NSArray<NSArray*>* pool = zeroPlays.count > 0 ? zeroPlays : candidates;
    NSArray* chosen = pool[arc4random_uniform((uint32_t)pool.count)];
    Torrent* torrent = chosen[0];
    NSDictionary* item = chosen[1];
    [self.fTableView playMediaItem:item forTorrent:torrent];
}

- (NSArray*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
    return @[
        ToolbarItemIdentifierCreate,
        ToolbarItemIdentifierOpenFile,
        ToolbarItemIdentifierOpenWeb,
        ToolbarItemIdentifierRemove,
        ToolbarItemIdentifierRemoveTrash,
        ToolbarItemIdentifierPauseResumeSelected,
        ToolbarItemIdentifierPauseResumeAll,
        ToolbarItemIdentifierShare,
        ToolbarItemIdentifierQuickLook,
        ToolbarItemIdentifierFilter,
        ToolbarItemIdentifierInfo,
        ToolbarItemIdentifierSearch,
        ToolbarItemIdentifierPlayRandomAudio,
        NSToolbarSpaceItemIdentifier,
        NSToolbarFlexibleSpaceItemIdentifier
    ];
}

- (NSArray*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
    return @[
        ToolbarItemIdentifierCreate,
        ToolbarItemIdentifierOpenFile,
        ToolbarItemIdentifierRemove,
        ToolbarItemIdentifierRemoveTrash,
        NSToolbarFlexibleSpaceItemIdentifier,
        ToolbarItemIdentifierSearch,
        NSToolbarFlexibleSpaceItemIdentifier,
        ToolbarItemIdentifierPauseResumeAll,
        ToolbarItemIdentifierShare,
        ToolbarItemIdentifierQuickLook,
        ToolbarItemIdentifierFilter,
        ToolbarItemIdentifierInfo,
        ToolbarItemIdentifierPlayRandomAudio,
    ];
}

- (BOOL)validateToolbarItem:(NSToolbarItem*)toolbarItem
{
    NSString* ident = toolbarItem.itemIdentifier;

    if ([ident isEqualToString:ToolbarItemIdentifierRemove] || [ident isEqualToString:ToolbarItemIdentifierRemoveTrash])
        return self.fTableView.numberOfSelectedRows > 0;

    if ([ident isEqualToString:ToolbarItemIdentifierPauseAll])
    {
        for (Torrent* torrent in self.fTorrents)
        {
            if (torrent.active || torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierResumeAll])
    {
        for (Torrent* torrent in self.fTorrents)
        {
            if (!torrent.active && !torrent.waitingToStart && !torrent.finishedSeeding)
                return YES;
        }
        return NO;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierPauseSelected])
    {
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (torrent.active || torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierResumeSelected])
    {
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (!torrent.active && !torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierInfo])
    {
        ((NSButton*)toolbarItem.view).state = self.fInfoController.window.visible;
        return YES;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierFilter])
    {
        BOOL shown = !(self.fFilterBar == nil || self.fFilterBar.isHidden);
        ((NSButton*)toolbarItem.view).state = shown ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierQuickLook])
    {
        ((NSButton*)toolbarItem.view).state = self.fPreviewPanel != nil;
        return self.fTableView.numberOfSelectedRows > 0;
    }

    if ([ident isEqualToString:ToolbarItemIdentifierShare])
        return self.fTableView.numberOfSelectedRows > 0;

    if ([ident isEqualToString:ToolbarItemIdentifierPlayRandomAudio])
        return YES;

    return YES;
}

@end
#pragma clang diagnostic pop
