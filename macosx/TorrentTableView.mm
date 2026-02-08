// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "CocoaCompatibility.h"

#import "TorrentTableView.h"
#import "TorrentTableViewPrivate.h"
#import "Controller.h"
#import "FileListNode.h"
#import "IINAWatchHelper.h"
#import "PlayButtonStateBuilder.h"
#import "InfoOptionsViewController.h"
#import "NSKeyedUnarchiverAdditions.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentCell.h"
#import "SmallTorrentCell.h"
#import "GroupCell.h"
#import "TorrentGroup.h"
#import "GroupsController.h"
#import "NSImageAdditions.h"
#import "TorrentCellActionButton.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <cmath>
#import <objc/runtime.h>
#import "TorrentCellControlButton.h"
#import "TorrentCellRevealButton.h"
#import "TorrentCellURLButton.h"
#import "PlayButton.h"
#import "FlowLayoutView.h"

CGFloat const kGroupSeparatorHeight = 18.0;

static NSInteger const kMaxGroup = 999999;
static CGFloat const kErrorImageSize = 20.0;

static NSTimeInterval const kToggleProgressSeconds = 0.175;

// Associated object keys for play buttons (shared with TorrentTableView+Flow.mm; extern for C++ linkage)
extern char const kPlayButtonTypeKey = '\0';
extern char const kPlayButtonFolderKey = '\0';
extern char const kPlayButtonRepresentedKey = '\0';

@implementation TorrentTableView

- (instancetype)initWithCoder:(NSCoder*)decoder
{
    if ((self = [super initWithCoder:decoder]))
    {
        _fDefaults = NSUserDefaults.standardUserDefaults;

        NSData* groupData;
        if ((groupData = [_fDefaults dataForKey:@"CollapsedGroupIndexes"]))
        {
            _fCollapsedGroups = [NSKeyedUnarchiver unarchivedObjectOfClass:NSMutableIndexSet.class fromData:groupData error:nil];
        }
        else if ((groupData = [_fDefaults dataForKey:@"CollapsedGroups"])) //handle old groups
        {
            _fCollapsedGroups = [[NSKeyedUnarchiver deprecatedUnarchiveObjectWithData:groupData] mutableCopy];
            [_fDefaults removeObjectForKey:@"CollapsedGroups"];
            [self saveCollapsedGroups];
        }
        if (_fCollapsedGroups == nil)
        {
            _fCollapsedGroups = [[NSMutableIndexSet alloc] init];
        }

        _fActionPopoverShown = NO;

        self.delegate = self;
        self.indentationPerLevel = 0;

        _piecesBarPercent = [_fDefaults boolForKey:@"PiecesBar"] ? 1.0 : 0.0;

        _fIconCache = [[NSCache alloc] init];
        _fIconCache.name = @"PlayMenuIconCache";

        _fPlayMenuCache = [NSMapTable weakToStrongObjectsMapTable];

        _fPlayButtonPool = [[NSMutableArray alloc] init];
        _fHeaderPool = [[NSMutableArray alloc] init];
        _fPendingHeightRows = [[NSMutableIndexSet alloc] init];

        _fFlowViewCache = [[NSCache alloc] init];
        _fFlowViewCache.countLimit = 80;

        _fPendingFlowConfigs = [[NSMutableArray alloc] init];
        _fPendingFlowApplies = [[NSMutableArray alloc] init];

        self.style = NSTableViewStyleFullWidth;
    }

    return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    self.fContextRow.delegate = self;
    self.fLastKnownWidth = self.bounds.size.width;
    [self updateDefaultsCache];

    NSScrollView* scrollView = self.enclosingScrollView;
    if (scrollView)
    {
        self.fScrollViewPreviousDelegate = [scrollView valueForKey:@"delegate"];
        [scrollView setValue:self forKey:@"delegate"];
    }

    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refreshTorrentTable) name:@"RefreshTorrentTable" object:nil];
    [nc addObserver:self selector:@selector(updateVisiblePlayButtons) name:@"UpdateUI" object:nil];
    [nc addObserver:self selector:@selector(iinaWatchCacheDidUpdate:) name:kIINAWatchCacheDidUpdateNotification object:nil];
    [nc addObserver:self selector:@selector(updateDefaultsCache) name:NSUserDefaultsDidChangeNotification object:nil];

    // Pre-warm button pool asynchronously to avoid startup lag
    dispatch_async(dispatch_get_main_queue(), ^{
        [self prewarmButtonPool];
    });
}

- (void)prewarmButtonPool
{
    // Create buttons in the pool so they're ready when needed.
    // Increasing to 200 to handle multiple visible torrents with many files (e.g. music albums)
    NSUInteger const poolSize = 200;
    for (NSUInteger i = 0; i < poolSize; i++)
    {
        PlayButton* button = [[PlayButton alloc] init];
        button.target = self;
        button.action = @selector(playContextItem:);
        [self.fPlayButtonPool addObject:button];
    }

    // Pre-warm header pool too (text color set by TorrentCell.setBackgroundStyle)
    for (NSUInteger i = 0; i < 20; i++)
    {
        NSTextField* field = [NSTextField labelWithString:@""];
        field.font = [NSFont boldSystemFontOfSize:11];
        field.wantsLayer = YES;
        [self.fHeaderPool addObject:field];
    }
}

- (void)viewDidEndLiveResize
{
    [super viewDidEndLiveResize];
    CGFloat currentWidth = self.bounds.size.width;
    if (fabs(currentWidth - self.fLastKnownWidth) > 10.0)
    {
        self.fLastKnownWidth = currentWidth;
        [self reloadData];
    }
}

- (void)updateDefaultsCache
{
    self.fSmallView = [self.fDefaults boolForKey:@"SmallView"];
    self.fSortByGroup = [self.fDefaults boolForKey:@"SortByGroup"];
    self.fDisplaySmallStatusRegular = [self.fDefaults boolForKey:@"DisplaySmallStatusRegular"];
    self.fDisplayGroupRowRatio = [self.fDefaults boolForKey:@"DisplayGroupRowRatio"];
}

- (void)refreshTorrentTable
{
    self.needsDisplay = YES;
}

- (void)iinaWatchCacheDidUpdate:(NSNotification*)notification
{
    Torrent* torrent = notification.object;
    if (![torrent isKindOfClass:[Torrent class]])
        return;
    torrent.cachedPlayButtonState = nil;
    torrent.cachedPlayButtonLayout = nil;
    [self updateVisiblePlayButtons];
}

/// Called on UpdateUI. Refreshes visible torrent rows in place so play buttons and status stay in sync (no row re-request, no flicker).
- (void)updateVisiblePlayButtons
{
    [self refreshVisibleTorrentRowsInPlace];
}

//make sure we don't lose selection on manual reloads
- (void)reloadData
{
    NSArray<Torrent*>* selectedTorrents = self.selectedTorrents;
    [super reloadData];
    self.selectedTorrents = selectedTorrents;
}

/// Row indexes that are currently visible. With SortByGroup, includes floating group rows in the range.
- (NSIndexSet*)visibleRowIndexSet
{
    NSRect visibleRect = self.visibleRect;
    NSRange range = [self rowsInRect:visibleRect];
    if (![self.fDefaults boolForKey:@"SortByGroup"])
        return [NSIndexSet indexSetWithIndexesInRange:range];
    NSRange fullRange = NSMakeRange(0, range.location + range.length);
    NSMutableIndexSet* visibleIndexSet = [NSMutableIndexSet indexSet];
    [[NSIndexSet indexSetWithIndexesInRange:fullRange] enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        id rowItem = [self itemAtRow:row];
        if ([rowItem isKindOfClass:[TorrentGroup class]] || NSIntersectsRect(visibleRect, [self rectOfRow:row]))
            [visibleIndexSet addIndex:row];
    }];
    return visibleIndexSet;
}

/// Refreshes all visible torrent rows in place (status, progress, hover, control button). Does not re-request row views, so flow views do not flicker.
- (void)refreshVisibleTorrentRowsInPlace
{
    NSIndexSet* visible = [self visibleRowIndexSet];
    [visible enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        if ([[self itemAtRow:row] isKindOfClass:[Torrent class]])
            [self refreshTorrentRowInPlace:(NSInteger)row];
    }];
}

- (void)updateVisibleRowsContent
{
    [self refreshVisibleTorrentRowsInPlace];
}

/// Single place for the Show Content Buttons preference (View menu).
- (BOOL)showContentButtonsPref
{
    return [self.fDefaults boolForKey:@"ShowContentButtons"];
}

/// Call when Show Content Buttons preference changes so row heights and content button containers redraw immediately.
- (void)refreshContentButtonsVisibility
{
    NSIndexSet* allRows = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.numberOfRows)];
    [self beginUpdates];
    [self noteHeightOfRowsWithIndexesChanged:allRows];
    [self endUpdates];
    NSIndexSet* visible = [self visibleRowIndexSet];
    [visible enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        id item = [self itemAtRow:row];
        if (![item isKindOfClass:[Torrent class]])
            return;
        NSView* cellView = [self viewAtColumn:0 row:row makeIfNecessary:NO];
        if ([cellView isKindOfClass:[TorrentCell class]])
            [self configurePlayButtonsForCell:(TorrentCell*)cellView torrent:(Torrent*)item];
    }];
}

/// Schedules content button config for each visible torrent row that still needs it (e.g. after scroll).
/// Call when scroll ends so rows that got an empty flow view get buttons populated.
- (void)ensureContentButtonsForVisibleRows
{
    NSIndexSet* visible = [self visibleRowIndexSet];
    [visible enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        id item = [self itemAtRow:row];
        if (![item isKindOfClass:[Torrent class]])
            return;
        NSView* cellView = [self viewAtColumn:0 row:row makeIfNecessary:NO];
        if (![cellView isKindOfClass:[TorrentCell class]])
            return;
        TorrentCell* cell = (TorrentCell*)cellView;
        Torrent* torrent = (Torrent*)item;
        if ([self cellNeedsContentButtonsConfigForCell:cell torrent:torrent])
            [self scheduleConfigurePlayButtonsForCell:cell torrent:torrent];
    }];
}

- (void)scrollViewDidEndLiveScroll:(id)scrollView
{
    [self ensureContentButtonsForVisibleRows];
    id prev = self.fScrollViewPreviousDelegate;
    if ([prev respondsToSelector:@selector(scrollViewDidEndLiveScroll:)])
        [prev scrollViewDidEndLiveScroll:scrollView];
}

- (void)reloadDataForRowIndexes:(NSIndexSet*)rowIndexes columnIndexes:(NSIndexSet*)columnIndexes
{
    [super reloadDataForRowIndexes:rowIndexes columnIndexes:columnIndexes];

    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        if (![[self itemAtRow:row] isKindOfClass:[TorrentGroup class]])
        {
            TorrentCell* cell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
            if ([cell isKindOfClass:[TorrentCell class]])
                [self resetControlButtonForTorrentCell:cell];
        }
    }];
}

- (BOOL)usesAlternatingRowBackgroundColors
{
    return !self.fSmallView;
}

- (BOOL)isGroupCollapsed:(NSInteger)value
{
    if (value == -1)
    {
        value = kMaxGroup;
    }

    return [self.fCollapsedGroups containsIndex:value];
}

- (void)removeCollapsedGroup:(NSInteger)value
{
    if (value == -1)
    {
        value = kMaxGroup;
    }

    [self.fCollapsedGroups removeIndex:value];
}

- (void)removeAllCollapsedGroups
{
    [self.fCollapsedGroups removeAllIndexes];
}

- (void)saveCollapsedGroups
{
    [self.fDefaults setObject:[NSKeyedArchiver archivedDataWithRootObject:self.fCollapsedGroups requiringSecureCoding:YES error:nil]
                       forKey:@"CollapsedGroupIndexes"];
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isGroupItem:(id)item
{
    // We are implementing our own group styling.
    // Apple's default group styling conflicts with this.
    return NO;
}

- (CGFloat)outlineView:(NSOutlineView*)outlineView heightOfRowByItem:(id)item
{
    if ([item isKindOfClass:[Torrent class]])
    {
        Torrent* torrent = (Torrent*)item;
        CGFloat height = self.rowHeight;

        // Content buttons uncollapsed: every row with playable content gets play button height so user can open any item with one click.
        BOOL showPlayButtonsHeight = !self.fSmallView && [self showContentButtonsPref];
        if (showPlayButtonsHeight)
        {
            CGFloat cachedHeight = torrent.cachedPlayButtonsHeight;
            if (cachedHeight > height && cachedHeight < height + 2000)
                height = cachedHeight;
        }

        return height;
    }
    return kGroupSeparatorHeight;
}

- (NSView*)outlineView:(NSOutlineView*)outlineView viewForTableColumn:(NSTableColumn*)tableColumn item:(id)item
{
    if ([item isKindOfClass:[Torrent class]])
    {
        Torrent* torrent = (Torrent*)item;
        BOOL const minimal = [self.fDefaults boolForKey:@"SmallView"];
        BOOL const error = torrent.anyErrorOrWarning;

        TorrentCell* torrentCell;
        NSString* torrentHash = torrent.hashString;

        if (minimal)
        {
            torrentCell = [outlineView makeViewWithIdentifier:@"SmallTorrentCell" owner:self];
            BOOL const sameTorrentMinimal = [torrentCell.fTorrentHash isEqualToString:torrentHash];

            if (!sameTorrentMinimal)
            {
                torrentCell.fTorrentHash = torrentHash;
                torrentCell.fIconView.image = error ? [NSImage imageNamed:NSImageNameCaution] : torrent.icon;
                torrentCell.fTorrentTitleField.stringValue = torrent.displayName;
            }

            if (torrentCell.fPlayButtonsView)
                torrentCell.fPlayButtonsView.hidden = YES;

            [self applyDynamicContentToTorrentCell:torrentCell torrent:torrent row:[self rowForItem:item]];
        }
        else
        {
            torrentCell = [outlineView makeViewWithIdentifier:@"TorrentCell" owner:self];
            BOOL const sameTorrentFull = [torrentCell.fTorrentHash isEqualToString:torrentHash];

            if (!sameTorrentFull && torrentCell.fPlayButtonsView)
            {
                [self recycleSubviewsFromFlowView:(FlowLayoutView*)torrentCell.fPlayButtonsView];
                [torrentCell.fPlayButtonsView removeFromSuperview];
                torrentCell.fPlayButtonsView = nil;
                torrentCell.fPlayButtonsSourceFiles = nil;
                torrentCell.fPlayButtonsHeightConstraint = nil;
            }
            if (!sameTorrentFull)
                torrentCell.fTorrentHash = torrentHash;
            if ([self cellNeedsContentButtonsConfigForCell:torrentCell torrent:torrent])
                [self scheduleConfigurePlayButtonsForCell:torrentCell torrent:torrent];

            // Static content - only update when torrent changes
            if (!sameTorrentFull)
            {
                // set torrent icon and error badge
                NSImage* fileImage = torrent.icon;
                if (error)
                {
                    NSRect frame = torrentCell.fIconView.frame;
                    if (frame.size.width > 0 && frame.size.height > 0)
                    {
                        torrentCell.fIconView.image = [NSImage imageWithSize:frame.size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
                            // draw fileImage
                            [fileImage drawInRect:dstRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                         fraction:1.0];

                            // overlay error badge
                            NSImage* errorImage = [NSImage imageNamed:NSImageNameCaution];
                            NSRect const errorRect = NSMakeRect(0, 0, kErrorImageSize, kErrorImageSize);
                            [errorImage drawInRect:errorRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                          fraction:1.0
                                    respectFlipped:YES
                                             hints:nil];
                            return YES;
                        }];
                    }
                    else
                    {
                        torrentCell.fIconView.image = [NSImage imageNamed:NSImageNameCaution];
                    }
                }
                else
                {
                    torrentCell.fIconView.image = fileImage;
                }

                // set icon subtitle label (e.g., "8 videos" for multi-file media torrents)
                NSString* iconSubtitle = torrent.iconSubtitle;
                torrentCell.fIconSubtitleField.stringValue = iconSubtitle ?: @"";
                torrentCell.fIconSubtitleField.hidden = (iconSubtitle == nil);

                // set torrent title
                torrentCell.fTorrentTitleField.stringValue = torrent.displayName;
            }

            torrentCell.fURLButton.hidden = (torrent.commentURL == nil);
            torrentCell.fTorrentStatusField.hidden = NO;
            torrentCell.fControlButton.hidden = NO;
            torrentCell.fRevealButton.hidden = NO;
            torrentCell.fIconView.hidden = NO;

            [self applyDynamicContentToTorrentCell:torrentCell torrent:torrent row:[self rowForItem:item]];
        }

        torrentCell.fTorrentTableView = self;

        // set this so that we can draw bar in torrentCell drawRect
        torrentCell.objectValue = torrent;

        // Actions need to be set (they reference the cell's objectValue)
        torrentCell.fActionButton.action = @selector(displayTorrentActionPopover:);
        torrentCell.fControlButton.action = @selector(toggleControlForTorrent:);
        torrentCell.fRevealButton.action = @selector(revealTorrentFile:);
        torrentCell.fURLButton.action = @selector(openCommentURL:);

        // Group indicator - only update if changed
        NSInteger const groupValue = torrent.groupValue;
        NSImage* groupImage = nil;
        if (groupValue != -1 && ![self.fDefaults boolForKey:@"SortByGroup"])
        {
            groupImage = [GroupsController.groups imageForIndex:groupValue];
        }
        if (torrentCell.fGroupIndicatorView.image != groupImage)
        {
            torrentCell.fGroupIndicatorView.image = groupImage;
        }

        return torrentCell;
    }
    else
    {
        TorrentGroup* group = (TorrentGroup*)item;
        GroupCell* groupCell = [outlineView makeViewWithIdentifier:@"GroupCell" owner:self];

        NSInteger groupIndex = group.groupIndex;

        NSColor* groupColor = groupIndex != -1 ? [GroupsController.groups colorForIndex:groupIndex] :
                                                 [NSColor colorWithWhite:1.0 alpha:0];
        groupCell.fGroupIndicatorView.image = [NSImage discIconWithColor:groupColor insetFactor:0];

        NSString* groupName = groupIndex != -1 ? [GroupsController.groups nameForIndex:groupIndex] :
                                                 NSLocalizedString(@"No Group", "Group table row");

        NSInteger row = [self rowForItem:item];
        if ([self isRowSelected:row])
        {
            NSMutableAttributedString* string = [[NSMutableAttributedString alloc] initWithString:groupName];
            NSDictionary* attributes = @{
                NSFontAttributeName : [NSFont boldSystemFontOfSize:11.0],
                NSForegroundColorAttributeName : [NSColor labelColor]
            };

            [string addAttributes:attributes range:NSMakeRange(0, string.length)];
            groupCell.fGroupTitleField.attributedStringValue = string;
        }
        else
        {
            groupCell.fGroupTitleField.stringValue = groupName;
        }

        BOOL displayGroupRowRatio = self.fDisplayGroupRowRatio;

        // Always hide speed indicators - they're broken and global speed is shown elsewhere
        groupCell.fGroupDownloadField.hidden = YES;
        groupCell.fGroupDownloadView.hidden = YES;

        if (displayGroupRowRatio)
        {
            groupCell.fGroupUploadAndRatioView.image = [NSImage imageNamed:@"YingYangGroupTemplate"];
            groupCell.fGroupUploadAndRatioView.image.accessibilityDescription = NSLocalizedString(@"Ratio", "Torrent -> status image");

            groupCell.fGroupUploadAndRatioField.stringValue = [NSString stringForRatio:group.ratio];

            NSString* tooltipRatio = NSLocalizedString(@"Ratio", "Torrent table -> group row -> tooltip");
            groupCell.fGroupUploadAndRatioField.toolTip = tooltipRatio;
            groupCell.fGroupUploadAndRatioView.toolTip = tooltipRatio;

            groupCell.fGroupUploadAndRatioField.hidden = NO;
            groupCell.fGroupUploadAndRatioView.hidden = NO;
        }
        else
        {
            // Hide upload speed indicator when not showing ratio
            groupCell.fGroupUploadAndRatioField.hidden = YES;
            groupCell.fGroupUploadAndRatioView.hidden = YES;
        }

        NSString* tooltipGroup;
        NSUInteger count = group.torrents.count;
        if (count == 1)
        {
            tooltipGroup = NSLocalizedString(@"1 transfer", "Torrent table -> group row -> tooltip");
        }
        else
        {
            tooltipGroup = NSLocalizedString(@"%lu transfers", "Torrent table -> group row -> tooltip");
            tooltipGroup = [NSString localizedStringWithFormat:tooltipGroup, count];
        }
        groupCell.toolTip = tooltipGroup;

        return groupCell;
    }
    return nil;
}

/// Updates status, progress, and hover state for a torrent cell. Does not touch flow view (play buttons).
- (void)applyDynamicContentToTorrentCell:(TorrentCell*)torrentCell torrent:(Torrent*)torrent row:(NSInteger)row
{
    BOOL const minimal = [torrentCell isKindOfClass:[SmallTorrentCell class]];

    if (minimal)
    {
        torrentCell.fTorrentStatusField.stringValue = self.fDisplaySmallStatusRegular ? torrent.shortStatusString : torrent.remainingTimeString;
    }
    else
    {
        NSString* progressString = torrent.progressString;
        if (![torrentCell.fTorrentProgressField.stringValue isEqualToString:progressString])
            torrentCell.fTorrentProgressField.stringValue = progressString;

        NSString* statusString = nil;
        if (self.fHoverEventDict && [self.fHoverEventDict[@"row"] integerValue] == row)
            statusString = self.fHoverEventDict[@"string"];
        if (!statusString)
            statusString = torrent.statusString;
        if (![torrentCell.fTorrentStatusField.stringValue isEqualToString:statusString])
            torrentCell.fTorrentStatusField.stringValue = statusString;
    }

    if (self.fHoverEventDict && [self.fHoverEventDict[@"row"] integerValue] == row)
    {
        torrentCell.fTorrentStatusField.hidden = YES;
        torrentCell.fControlButton.hidden = NO;
        torrentCell.fRevealButton.hidden = NO;
        torrentCell.fURLButton.hidden = (torrent.commentURL == nil);
    }
    else
    {
        torrentCell.fTorrentStatusField.hidden = NO;
        if (minimal)
        {
            torrentCell.fControlButton.hidden = YES;
            torrentCell.fRevealButton.hidden = YES;
            torrentCell.fURLButton.hidden = YES;
        }
    }
}

/// Resets the control button image for a torrent cell. Used after content updates so play/pause icon is correct.
- (void)resetControlButtonForTorrentCell:(TorrentCell*)cell
{
    if ([cell isKindOfClass:[TorrentCell class]] && cell.fControlButton)
        [(TorrentCellControlButton*)cell.fControlButton resetImage];
}

/// Updates one torrent row's cell in place (status, hover, control button, play button colors). Avoids reloadDataForRowIndexes so the flow view is not re-requested.
- (void)refreshTorrentRowInPlace:(NSInteger)row
{
    id item = [self itemAtRow:row];
    if (![item isKindOfClass:[Torrent class]])
        return;
    Torrent* torrent = (Torrent*)item;
    NSView* cellView = [self viewAtColumn:0 row:row makeIfNecessary:NO];
    if (![cellView isKindOfClass:[TorrentCell class]])
        return;
    TorrentCell* cell = (TorrentCell*)cellView;
    [self applyDynamicContentToTorrentCell:cell torrent:torrent row:row];
    [self resetControlButtonForTorrentCell:cell];
    [self refreshPlayButtonStateForCell:cell torrent:torrent];
    [cell setNeedsDisplay:YES];
}

- (NSString*)outlineView:(NSOutlineView*)outlineView typeSelectStringForTableColumn:(NSTableColumn*)tableColumn item:(id)item
{
    if ([item isKindOfClass:[Torrent class]])
    {
        return ((Torrent*)item).name;
    }
    else
    {
        return [self.dataSource outlineView:outlineView objectValueForTableColumn:[self tableColumnWithIdentifier:@"Group"]
                                     byItem:item];
    }
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification
{
    NSInteger oldSelected = self.fSelectedRowIndexes.count > 0 ? (NSInteger)self.fSelectedRowIndexes.firstIndex : -1;
    NSInteger newSelected = self.selectedRow;
    if (oldSelected != newSelected && (oldSelected >= 0 || newSelected >= 0))
    {
        NSMutableIndexSet* heightRows = [NSMutableIndexSet indexSet];
        if (oldSelected >= 0)
            [heightRows addIndex:(NSUInteger)oldSelected];
        if (newSelected >= 0)
            [heightRows addIndex:(NSUInteger)newSelected];
        [self noteHeightOfRowsWithIndexesChanged:heightRows];
    }
    self.fSelectedRowIndexes = self.selectedRowIndexes;
    if (oldSelected >= 0)
        [self refreshTorrentRowInPlace:oldSelected];
    if (newSelected >= 0 && newSelected != oldSelected)
        [self refreshTorrentRowInPlace:newSelected];
}

- (void)outlineViewItemDidExpand:(NSNotification*)notification
{
    TorrentGroup* group = notification.userInfo[@"NSObject"];
    NSInteger value = group.groupIndex;
    if (value < 0)
    {
        value = kMaxGroup;
    }

    if ([self.fCollapsedGroups containsIndex:value])
    {
        [self.fCollapsedGroups removeIndex:value];
        [NSNotificationCenter.defaultCenter postNotificationName:@"OutlineExpandCollapse" object:self];
    }
}

- (void)outlineViewItemDidCollapse:(NSNotification*)notification
{
    TorrentGroup* group = notification.userInfo[@"NSObject"];
    NSInteger value = group.groupIndex;
    if (value < 0)
    {
        value = kMaxGroup;
    }

    [self.fCollapsedGroups addIndex:value];
    [NSNotificationCenter.defaultCenter postNotificationName:@"OutlineExpandCollapse" object:self];
}

- (void)mouseDown:(NSEvent*)event
{
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger const row = [self rowAtPoint:point];

    [super mouseDown:event];

    id item = nil;
    if (row != -1)
    {
        item = [self itemAtRow:row];
    }

    if (event.clickCount == 2) //double click
    {
        if (!item || [item isKindOfClass:[Torrent class]])
        {
            if (item)
                [self handleDoubleClickOnTorrent:(Torrent*)item withEvent:event];
            else
                [self.fController showInfo:nil];
        }
        else
        {
            if ([self isItemExpanded:item])
                [self collapseItem:item];
            else
                [self expandItem:item];
        }
    }
    else if ([self pointInGroupStatusRect:point])
    {
        //we check for this here rather than in the GroupCell
        //as using floating group rows causes all sorts of weirdness...
        [self toggleGroupRowRatio];
    }
}

/// Handles double-click on a torrent row: play if one playable file, show play menu if multiple, else reveal in Finder if we have a location (unknown file types) or show Inspector.
- (void)handleDoubleClickOnTorrent:(Torrent*)torrent withEvent:(NSEvent*)event
{
    NSArray* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 1)
    {
        [self playTorrentMedia:torrent];
    }
    else if (playableFiles.count > 1)
    {
        NSMenu* menu = [self playMenuForTorrent:torrent];
        [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    }
    else if (torrent.dataLocation)
    {
        [self revealTorrentInFinder:torrent];
    }
    else
    {
        [self.fController showInfo:nil];
    }
}

- (void)scrollWheel:(NSEvent*)event
{
    [self.fController restorePriorityForUserInteraction];
    [super scrollWheel:event];
}

- (NSArray<Torrent*>*)selectedTorrents
{
    NSIndexSet* selectedIndexes = self.selectedRowIndexes;
    NSMutableArray* torrents = [NSMutableArray arrayWithCapacity:selectedIndexes.count]; //take a shot at guessing capacity

    for (NSUInteger i = selectedIndexes.firstIndex; i != NSNotFound; i = [selectedIndexes indexGreaterThanIndex:i])
    {
        id item = [self itemAtRow:i];
        if ([item isKindOfClass:[Torrent class]])
        {
            [torrents addObject:item];
        }
        else
        {
            NSArray* groupTorrents = ((TorrentGroup*)item).torrents;
            [torrents addObjectsFromArray:groupTorrents];
            if ([self isItemExpanded:item])
            {
                i += groupTorrents.count;
            }
        }
    }

    return torrents;
}

- (void)setSelectedTorrents:(NSArray<Torrent*>*)selectedTorrents
{
    NSMutableIndexSet* selectedIndexes = [NSMutableIndexSet new];
    for (Torrent* i in selectedTorrents)
    {
        [selectedIndexes addIndex:[self rowForItem:i]];
    }
    [self selectRowIndexes:selectedIndexes byExtendingSelection:NO];
}

/// Single source for (torrent, item) from context menu item or play button. Prefer context menu behavior (exact payload only).
- (BOOL)torrent:(Torrent* _Nullable*)outTorrent item:(NSDictionary* _Nullable*)outItem fromPlaySender:(id)sender
{
    NSDictionary* represented = nil;
    if ([sender isKindOfClass:[NSMenuItem class]])
        represented = [(NSMenuItem*)sender representedObject];
    else if ([sender isKindOfClass:[NSButton class]])
        represented = objc_getAssociatedObject(sender, &kPlayButtonRepresentedKey);
    if (![represented isKindOfClass:[NSDictionary class]])
    {
        if (outTorrent)
            *outTorrent = nil;
        if (outItem)
            *outItem = nil;
        return NO;
    }
    Torrent* t = represented[@"torrent"];
    NSDictionary* it = represented[@"item"];
    Torrent* validTorrent = [t isKindOfClass:[Torrent class]] ? t : nil;
    NSDictionary* validItem = [it isKindOfClass:[NSDictionary class]] ? it : nil;
    if (outTorrent)
        *outTorrent = validTorrent;
    if (outItem)
        *outItem = validItem;
    return (validTorrent != nil && validItem != nil);
}

- (void)playContextItem:(id)sender
{
    Torrent* torrent = nil;
    NSDictionary* item = nil;
    if (![self torrent:&torrent item:&item fromPlaySender:sender])
        return;
    [self playMediaItem:item forTorrent:torrent];
}

- (NSMenu*)menuForEvent:(NSEvent*)event
{
    NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (row >= 0)
    {
        if (![self isRowSelected:row])
        {
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        }

        [self updatePlayMenuForItem:[self itemAtRow:row]];

        return self.fContextRow;
    }
    else
    {
        [self deselectAll:self];
        return self.fContextNoRow;
    }
}

//make sure that the pause buttons become orange when holding down the option key
- (void)flagsChanged:(NSEvent*)event
{
    [self display];
    [super flagsChanged:event];
}

//option-command-f will focus the filter bar's search field
- (void)keyDown:(NSEvent*)event
{
    unichar const firstChar = [event.charactersIgnoringModifiers characterAtIndex:0];

    if (firstChar == 'f' && event.modifierFlags & NSEventModifierFlagOption && event.modifierFlags & NSEventModifierFlagCommand)
    {
        [self.fController focusFilterField];
    }
    else if (firstChar == ' ')
    {
        [self.fController toggleQuickLook:nil];
    }
    else if (event.keyCode == 53) //esc key
    {
        [self deselectAll:nil];
    }
    else
    {
        [super keyDown:event];
    }
}

- (NSRect)iconRectForRow:(NSInteger)row
{
    BOOL minimal = [self.fDefaults boolForKey:@"SmallView"];
    NSRect rect;

    if (minimal)
    {
        SmallTorrentCell* smallCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
        rect = smallCell.fActionButton.frame;
    }
    else
    {
        TorrentCell* torrentCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
        rect = torrentCell.fIconView.frame;
    }

    NSRect rowRect = [self rectOfRow:row];
    rect.origin.y += rowRect.origin.y;
    rect.origin.x += self.intercellSpacing.width;
    return rect;
}

- (BOOL)acceptsFirstResponder
{
    // add support to `copy:`
    return YES;
}

- (void)copy:(id)sender
{
    NSArray<Torrent*>* selectedTorrents = self.selectedTorrents;
    if (selectedTorrents.count == 0)
    {
        return;
    }
    NSPasteboard* pasteBoard = NSPasteboard.generalPasteboard;
    NSString* links = [[selectedTorrents valueForKeyPath:@"magnetLink"] componentsJoinedByString:@"\n"];
    [pasteBoard declareTypes:@[ NSPasteboardTypeString ] owner:nil];
    [pasteBoard setString:links forType:NSPasteboardTypeString];
}

- (void)paste:(id)sender
{
    [self.fController openPasteboard];
}

- (void)menu:(NSMenu*)menu willHighlightItem:(NSMenuItem*)item
{
    if (item && item.action == @selector(playContextItem:))
    {
        Torrent* torrent = nil;
        NSDictionary* fileItem = nil;
        if ([self torrent:&torrent item:&fileItem fromPlaySender:item])
            [self setHighPriorityForItem:fileItem forTorrent:torrent];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
    SEL action = menuItem.action;

    if (action == @selector(paste:))
    {
        if ([NSPasteboard.generalPasteboard.types containsObject:NSPasteboardTypeURL])
        {
            return YES;
        }

        NSArray* items = [NSPasteboard.generalPasteboard readObjectsForClasses:@[ [NSString class] ] options:nil];
        if (items)
        {
            NSDataDetector* detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
            for (__strong NSString* pbItem in items)
            {
                pbItem = [pbItem stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (([pbItem rangeOfString:@"magnet:" options:(NSAnchoredSearch | NSCaseInsensitiveSearch)].location != NSNotFound) ||
                    [detector firstMatchInString:pbItem options:0 range:NSMakeRange(0, pbItem.length)])
                {
                    return YES;
                }
            }
        }

        return NO;
    }

    return YES;
}

- (void)hoverEventBeganForView:(id)view
{
    NSInteger row = [self rowForView:view];
    Torrent* torrent = [self itemAtRow:row];

    BOOL minimal = self.fSmallView;
    if (minimal)
    {
        if ([view isKindOfClass:[SmallTorrentCell class]])
        {
            self.fHoverEventDict = @{ @"row" : [NSNumber numberWithInteger:row] };
        }
        else if ([view isKindOfClass:[TorrentCellActionButton class]])
        {
            SmallTorrentCell* smallCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
            smallCell.fIconView.hidden = YES;
        }
    }
    else
    {
        NSString* statusString;
        if ([view isKindOfClass:[TorrentCellRevealButton class]])
        {
            statusString = NSLocalizedString(@"Show data file in Finder", "Torrent cell -> button info");
        }
        else if ([view isKindOfClass:[TorrentCellControlButton class]])
        {
            if (torrent.active)
                statusString = NSLocalizedString(@"Pause transfer", "Torrent Table -> tooltip");
            else
            {
                if (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption)
                {
                    statusString = NSLocalizedString(@"Resume transfer right away", "Torrent cell -> button info");
                }
                else if (torrent.waitingToStart)
                {
                    statusString = NSLocalizedString(@"Stop waiting to start", "Torrent cell -> button info");
                }
                else
                {
                    statusString = NSLocalizedString(@"Resume transfer", "Torrent cell -> button info");
                }
            }
        }
        else if ([view isKindOfClass:[TorrentCellActionButton class]])
        {
            statusString = NSLocalizedString(@"Change transfer settings", "Torrent Table -> tooltip");
        }
        else if ([view isKindOfClass:[TorrentCellURLButton class]])
        {
            statusString = NSLocalizedString(@"Open torrent's comment URL", "Torrent cell -> button info");
        }

        if (statusString)
        {
            self.fHoverEventDict = @{ @"string" : statusString, @"row" : [NSNumber numberWithInteger:row] };
        }
    }

    [self refreshTorrentRowInPlace:row];
}

- (void)hoverEventEndedForView:(id)view
{
    NSInteger row = [self rowForView:[view superview]];

    BOOL update = YES;
    BOOL minimal = self.fSmallView;
    if (minimal)
    {
        if (minimal && ![view isKindOfClass:[SmallTorrentCell class]])
        {
            if ([view isKindOfClass:[TorrentCellActionButton class]])
            {
                SmallTorrentCell* smallCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
                smallCell.fIconView.hidden = NO;
            }
            update = NO;
        }
    }

    if (update)
    {
        self.fHoverEventDict = nil;
        [self refreshTorrentRowInPlace:row];
    }
}

- (void)toggleGroupRowRatio
{
    BOOL displayGroupRowRatio = self.fDisplayGroupRowRatio;
    [self.fDefaults setBool:!displayGroupRowRatio forKey:@"DisplayGroupRowRatio"];
    [self updateDefaultsCache];
    NSIndexSet* visible = [self visibleRowIndexSet];
    NSMutableIndexSet* groupRows = [NSMutableIndexSet indexSet];
    [visible enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        if ([[self itemAtRow:(NSInteger)row] isKindOfClass:[TorrentGroup class]])
            [groupRows addIndex:row];
    }];
    if (groupRows.count > 0)
        [self reloadDataForRowIndexes:groupRows columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

- (IBAction)toggleControlForTorrent:(id)sender
{
    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    if (torrent.active)
    {
        [self.fController stopTorrents:@[ torrent ]];
    }
    else
    {
        if (NSEvent.modifierFlags & NSEventModifierFlagOption)
        {
            [self.fController resumeTorrentsNoWait:@[ torrent ]];
        }
        else if (torrent.waitingToStart)
        {
            [self.fController stopTorrents:@[ torrent ]];
        }
        else
        {
            [self.fController resumeTorrents:@[ torrent ]];
        }
    }
}

/// Reveals the torrent's data location in Finder (folder: open; single file: select). No-op if no location.
- (void)revealTorrentInFinder:(Torrent*)torrent
{
    NSString* location = torrent.dataLocation;
    if (!location)
        return;
    NSURL* file = [location fileURLForOpening];
    if (torrent.folder)
        [NSWorkspace.sharedWorkspace openURL:file];
    else
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ file ]];
}

- (IBAction)revealTorrentFile:(id)sender
{
    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    [self revealTorrentInFinder:torrent];
}

- (IBAction)openCommentURL:(id)sender
{
    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    NSURL* url = torrent.commentURL;
    if (url)
    {
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

static id playButtonFolderCache(NSButton* sender)
{
    return objc_getAssociatedObject(sender, &kPlayButtonFolderKey);
}

static void setPlayButtonFolderCache(NSButton* sender, id value)
{
    objc_setAssociatedObject(sender, &kPlayButtonFolderKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString*)folderForPlayButton:(NSButton*)sender torrent:(Torrent*)torrent
{
    id cached = playButtonFolderCache(sender);
    if ([cached isKindOfClass:[NSString class]])
        return (NSString*)cached;
    if (cached == [NSNull null])
        return nil;

    NSString* path = sender.identifier;
    if (!path)
    {
        setPlayButtonFolderCache(sender, [NSNull null]);
        return nil;
    }
    NSString* currentDir = torrent.currentDirectory;
    if (![path hasPrefix:currentDir])
    {
        setPlayButtonFolderCache(sender, [NSNull null]);
        return nil;
    }
    NSString* folder = [path substringFromIndex:currentDir.length];
    if ([folder hasPrefix:@"/"])
        folder = [folder substringFromIndex:1];
    if (folder.length == 0)
    {
        setPlayButtonFolderCache(sender, [NSNull null]);
        return nil;
    }
    setPlayButtonFolderCache(sender, folder);
    return folder;
}

- (NSIndexSet*)fileIndexesWithPriority:(tr_priority_t)priority torrent:(Torrent*)torrent
{
    NSUInteger fileCount = torrent.fileCount;
    NSMutableIndexSet* indexes = [[NSMutableIndexSet alloc] init];
    tr_torrent* handle = torrent.torrentStruct;

    for (tr_file_index_t i = 0; i < fileCount; ++i)
    {
        if (![torrent canChangeDownloadCheckForFile:i] || [torrent fileProgressForIndex:i] >= 1.0)
            continue;
        if (tr_torrentFile(handle, i).priority == priority)
            [indexes addIndex:i];
    }

    return indexes;
}

- (NSIndexSet*)otherHighPriorityIndexesForTorrent:(Torrent*)torrent excluding:(NSIndexSet*)excluded
{
    NSMutableIndexSet* highIndexes = [[self fileIndexesWithPriority:TR_PRI_HIGH torrent:torrent] mutableCopy];
    [highIndexes removeIndexes:excluded];
    return highIndexes;
}

- (void)playTorrentMedia:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        [self.fController showInfo:nil];
        return;
    }
    NSDictionary* bestItem = [torrent preferredPlayableItemFromList:playableFiles];
    if (bestItem)
        [self playMediaItem:bestItem forTorrent:torrent];
}

- (NSIndexSet*)targetFileIndexesForPlayItem:(NSDictionary*)item torrent:(Torrent*)torrent isComplete:(BOOL*)isComplete
{
    NSNumber* fileIndex = item[@"index"];
    if (fileIndex && fileIndex.integerValue != NSNotFound)
    {
        if (isComplete != NULL)
            *isComplete = ([torrent fileProgressForIndex:fileIndex.integerValue] >= 1.0);
        return [NSIndexSet indexSetWithIndex:fileIndex.integerValue];
    }

    NSString* folder = item[@"folder"];
    NSIndexSet* fileIndexes = (folder.length > 0) ? [torrent fileIndexesForFolder:folder] : nil;
    if (isComplete != NULL)
        *isComplete = (fileIndexes.count == 0) || (folder.length == 0) || ([torrent folderConsecutiveProgress:folder] >= 1.0);

    return fileIndexes;
}

- (void)setHighPriorityForItem:(NSDictionary*)item forTorrent:(Torrent*)torrent
{
    if (!torrent)
        return;

    BOOL isComplete = NO;
    NSIndexSet* targetIndexes = [self targetFileIndexesForPlayItem:item torrent:torrent isComplete:&isComplete];
    if (isComplete || targetIndexes.count == 0)
        return;

    // Track that these files were played in this session
    [torrent.playedFiles addIndexes:targetIndexes];

    NSIndexSet* otherHighIndexes = [self otherHighPriorityIndexesForTorrent:torrent excluding:targetIndexes];
    if (otherHighIndexes.count > 0)
    {
        // Only demote to Normal if the file was played in this session.
        // Otherwise, it might be a file the user manually set to High, so we can demote it to Low.
        NSMutableIndexSet* toNormal = [NSMutableIndexSet indexSet];
        NSMutableIndexSet* toLow = [NSMutableIndexSet indexSet];

        [otherHighIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* /*stop*/) {
            if ([torrent.playedFiles containsIndex:idx])
            {
                [toNormal addIndex:idx];
            }
            else
            {
                [toLow addIndex:idx];
            }
        }];

        if (toNormal.count > 0)
        {
            [torrent setFilePriority:TR_PRI_NORMAL forIndexes:toNormal];
        }
        if (toLow.count > 0)
        {
            [torrent setFilePriority:TR_PRI_LOW forIndexes:toLow];
        }
    }

    [torrent setFilePriority:TR_PRI_HIGH forIndexes:targetIndexes];
}

- (void)playMediaItem:(NSDictionary*)item forTorrent:(Torrent*)torrent
{
    [self setHighPriorityForItem:item forTorrent:torrent];

    [torrent recordOpenForPlayableItem:item];

    // Update last played date for the torrent
    tr_torrentSetLastPlayedDate(torrent.torrentStruct, time(nullptr));

    NSString* path = [torrent pathToOpenForPlayableItem:item];
    if (!path || path.length == 0)
        return;

    NSString* resolved = [torrent resolvePathInTorrent:path];
    if (resolved.length > 0)
        path = resolved;

    [Torrent invalidateIINAWatchCacheForPath:path];
    NSString* itemPath = item[@"path"];
    if (itemPath && ![itemPath isEqualToString:path])
        [Torrent invalidateIINAWatchCacheForPath:itemPath];
    torrent.cachedPlayButtonState = nil;
    torrent.cachedPlayButtonLayout = nil;
    [self updateVisiblePlayButtons];

    NSString* type = item[@"type"];
    NSURL* fileURL = [NSURL fileURLWithPath:path];

    if ([type isEqualToString:@"document-books"])
    {
        NSURL* booksURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Books"];
        if (booksURL)
        {
            NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
            [NSWorkspace.sharedWorkspace openURLs:@[ fileURL ] withApplicationAtURL:booksURL configuration:config
                                completionHandler:nil];
            return;
        }
    }
    else if ([type isEqualToString:@"document"])
    {
        [NSWorkspace.sharedWorkspace openURL:fileURL];
        return;
    }
    else if ([type isEqualToString:@"dvd"] || [type isEqualToString:@"bluray"])
    {
        // DVD/Blu-ray: try VLC first, then IINA, then default
        NSURL* vlcURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"org.videolan.vlc"];
        if (vlcURL)
        {
            NSTask* task = [[NSTask alloc] init];
            task.executableURL = [vlcURL URLByAppendingPathComponent:@"Contents/MacOS/VLC"];
            task.arguments = @[ path ];
            [task launchAndReturnError:nil];
            return;
        }

        NSURL* iinaURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.colliderli.iina"];
        if (iinaURL)
        {
            NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
            [NSWorkspace.sharedWorkspace openURLs:@[ fileURL ] withApplicationAtURL:iinaURL configuration:config
                                completionHandler:nil];
            return;
        }
    }
    else if ([type isEqualToString:@"album"])
    {
        // Album folder: try IINA first, then default music player
        // IINA can handle cue+flac albums better than most music players
        NSURL* iinaURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.colliderli.iina"];

        // path already set from pathToOpenForPlayableItem (folder vs .cue by count)
        fileURL = [NSURL fileURLWithPath:path];
        if (iinaURL)
        {
            NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
            [NSWorkspace.sharedWorkspace openURLs:@[ fileURL ] withApplicationAtURL:iinaURL configuration:config
                                completionHandler:nil];
            return;
        }

        // Fallback: open with default music player
        // Find the default app for mp3 files and use it to open the folder
        NSURL* musicPlayerURL = nil;
        if (@available(macOS 12.0, *))
        {
            musicPlayerURL = [NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:UTTypeMP3];
        }
        if (musicPlayerURL)
        {
            NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
            [NSWorkspace.sharedWorkspace openURLs:@[ fileURL ] withApplicationAtURL:musicPlayerURL configuration:config
                                completionHandler:nil];
            return;
        }
    }

    // CUE files: use IINA (handles cue+flac well)
    if ([path.pathExtension.lowercaseString isEqualToString:@"cue"])
    {
        NSURL* iinaURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.colliderli.iina"];
        if (iinaURL)
        {
            NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
            [NSWorkspace.sharedWorkspace openURLs:@[ fileURL ] withApplicationAtURL:iinaURL configuration:config
                                completionHandler:nil];
            return;
        }
    }

    // File or fallback: open with default app
    [NSWorkspace.sharedWorkspace openURL:fileURL];
}

- (void)setHighPriorityForButton:(NSButton*)sender
{
    Torrent* torrent = nil;
    NSDictionary* item = nil;
    if (![self torrent:&torrent item:&item fromPlaySender:sender])
        return;
    [self setHighPriorityForItem:item forTorrent:torrent];
}

- (NSInteger)rowForViewOrAncestor:(NSView*)view
{
    for (NSView* v = view; v != nil; v = v.superview)
    {
        NSInteger row = [self rowForView:v];
        if (row >= 0)
            return row;
    }
    return -1;
}

- (IBAction)displayTorrentActionPopover:(id)sender
{
    if (self.fActionPopoverShown)
    {
        return;
    }

    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    NSRect rect = [sender bounds];

    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    InfoOptionsViewController* infoViewController = [[InfoOptionsViewController alloc] init];
    popover.contentViewController = infoViewController;
    popover.delegate = self;

    [popover showRelativeToRect:rect ofView:sender preferredEdge:NSMaxYEdge];
    [infoViewController setInfoForTorrents:@[ torrent ]];
    [infoViewController updateInfo];

    CGFloat width = NSWidth(rect);

    if (NSMinX(self.window.frame) < width || NSMaxX(self.window.screen.visibleFrame) - NSMinX(self.window.frame) < 72)
    {
        // Ugly hack to hide NSPopover arrow.
        self.fPositioningView = [[NSView alloc] initWithFrame:rect];
        self.fPositioningView.identifier = @"positioningView";
        [self addSubview:self.fPositioningView];
        [popover showRelativeToRect:self.fPositioningView.bounds ofView:self.fPositioningView preferredEdge:NSMaxYEdge];
        self.fPositioningView.bounds = NSOffsetRect(self.fPositioningView.bounds, 0, NSHeight(self.fPositioningView.bounds));
    }
    else
    {
        [popover showRelativeToRect:rect ofView:sender preferredEdge:NSMaxYEdge];
    }
}

//don't show multiple popovers when clicking the gear button repeatedly
- (void)popoverWillShow:(NSNotification*)notification
{
    self.fActionPopoverShown = YES;
}

- (void)popoverDidClose:(NSNotification*)notification
{
    [self.fPositioningView removeFromSuperview];
    self.fPositioningView = nil;
    self.fActionPopoverShown = NO;
}

- (void)togglePiecesBar
{
    NSMutableArray* progressMarks = [NSMutableArray arrayWithCapacity:16];
    for (NSAnimationProgress i = 0.0625; i <= 1.0; i += 0.0625)
    {
        [progressMarks addObject:@(i)];
    }

    //this stops a previous animation
    self.fPiecesBarAnimation = [[NSAnimation alloc] initWithDuration:kToggleProgressSeconds animationCurve:NSAnimationEaseIn];
    self.fPiecesBarAnimation.animationBlockingMode = NSAnimationNonblocking;
    self.fPiecesBarAnimation.progressMarks = progressMarks;
    self.fPiecesBarAnimation.delegate = self;

    [self.fPiecesBarAnimation startAnimation];
}

- (void)animationDidEnd:(NSAnimation*)animation
{
    if (animation == self.fPiecesBarAnimation)
    {
        self.fPiecesBarAnimation = nil;
    }
}

- (void)animation:(NSAnimation*)animation didReachProgressMark:(NSAnimationProgress)progress
{
    if (animation == self.fPiecesBarAnimation)
    {
        if ([self.fDefaults boolForKey:@"PiecesBar"])
        {
            self.piecesBarPercent = progress;
        }
        else
        {
            self.piecesBarPercent = 1.0 - progress;
        }

        self.needsDisplay = YES;
    }
}

- (void)selectAndScrollToRow:(NSInteger)row
{
    NSParameterAssert(row >= 0);
    NSParameterAssert(row < self.numberOfRows);

    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];

    NSRect const rowRect = [self rectOfRow:row];
    NSRect const viewRect = self.superview.frame;

    NSPoint scrollOrigin = rowRect.origin;
    scrollOrigin.y += (rowRect.size.height - viewRect.size.height) / 2;
    if (scrollOrigin.y < 0)
    {
        scrollOrigin.y = 0;
    }

    [[self.superview animator] setBoundsOrigin:scrollOrigin];
}

#pragma mark - Private

- (BOOL)pointInGroupStatusRect:(NSPoint)point
{
    NSInteger row = [self rowAtPoint:point];
    if (![[self itemAtRow:row] isKindOfClass:[TorrentGroup class]])
    {
        return NO;
    }

    //check if click is within the status/ratio rect
    GroupCell* groupCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
    NSRect titleRect = groupCell.fGroupTitleField.frame;
    CGFloat maxX = NSMaxX(titleRect);

    return point.x > maxX;
}

@end
