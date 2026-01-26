// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "CocoaCompatibility.h"

#import "TorrentTableView.h"
#import "Controller.h"
#import "FileListNode.h"
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

@interface TorrentTableView ()

@property(nonatomic) IBOutlet Controller* fController;

@property(nonatomic, readonly) NSUserDefaults* fDefaults;

@property(nonatomic, readonly) NSMutableIndexSet* fCollapsedGroups;

@property(nonatomic) IBOutlet NSMenu* fContextRow;
@property(nonatomic) IBOutlet NSMenu* fContextNoRow;

@property(nonatomic) NSIndexSet* fSelectedRowIndexes;

@property(nonatomic) CGFloat piecesBarPercent;
@property(nonatomic) NSAnimation* fPiecesBarAnimation;

@property(nonatomic) BOOL fActionPopoverShown;
@property(nonatomic) NSView* fPositioningView;

@property(nonatomic) NSDictionary* fHoverEventDict;
@property(nonatomic) CGFloat fLastKnownWidth;

// Cached UserDefaults for faster access
@property(nonatomic) BOOL fSmallView;
@property(nonatomic) BOOL fSortByGroup;
@property(nonatomic) BOOL fDisplaySmallStatusRegular;
@property(nonatomic) BOOL fDisplayGroupRowRatio;

@property(nonatomic, readonly) NSCache<NSString*, NSImage*>* fIconCache;
@property(nonatomic, readonly) NSMapTable<Torrent*, NSMenu*>* fPlayMenuCache;

@end

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

    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refreshTorrentTable) name:@"RefreshTorrentTable" object:nil];
    [nc addObserver:self selector:@selector(updateVisiblePlayButtons) name:@"UpdateUI" object:nil];
    [nc addObserver:self selector:@selector(updateDefaultsCache) name:NSUserDefaultsDidChangeNotification object:nil];
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

- (void)updateVisiblePlayButtons
{
    NSRange visibleRows = [self rowsInRect:self.visibleRect];
    NSMutableIndexSet* rowsToUpdate = [[NSMutableIndexSet alloc] init];

    for (NSUInteger row = visibleRows.location; row < NSMaxRange(visibleRows); row++)
    {
        id item = [self itemAtRow:row];
        if (![item isKindOfClass:[Torrent class]])
            continue;

        Torrent* torrent = (Torrent*)item;
        (void)torrent; // Suppress unused variable warning

        [rowsToUpdate addIndex:row];
    }

    if (rowsToUpdate.count > 0)
    {
        [self reloadDataForRowIndexes:rowsToUpdate columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

//make sure we don't lose selection on manual reloads
- (void)reloadData
{
    NSArray<Torrent*>* selectedTorrents = self.selectedTorrents;
    [super reloadData];
    self.selectedTorrents = selectedTorrents;
}

- (void)reloadVisibleRows
{
    NSRect visibleRect = self.visibleRect;
    NSRange range = [self rowsInRect:visibleRect];

    //since we use floating group rows, we need some magic to find visible group rows
    if ([self.fDefaults boolForKey:@"SortByGroup"])
    {
        NSInteger location = range.location;
        NSInteger length = range.length;
        NSRange fullRange = NSMakeRange(0, length + location);
        NSIndexSet* fullIndexSet = [NSIndexSet indexSetWithIndexesInRange:fullRange];
        NSMutableIndexSet* visibleIndexSet = [[NSMutableIndexSet alloc] init];

        [fullIndexSet enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
            id rowItem = [self itemAtRow:row];
            if ([rowItem isKindOfClass:[TorrentGroup class]])
            {
                [visibleIndexSet addIndex:row];
            }
            else if (NSIntersectsRect(visibleRect, [self rectOfRow:row]))
            {
                [visibleIndexSet addIndex:row];
            }
        }];

        [self reloadDataForRowIndexes:visibleIndexSet columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
    else
    {
        [self reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:range] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

- (void)reloadDataForRowIndexes:(NSIndexSet*)rowIndexes columnIndexes:(NSIndexSet*)columnIndexes
{
    [super reloadDataForRowIndexes:rowIndexes columnIndexes:columnIndexes];

    //redraw fControlButton
    BOOL minimal = [self.fDefaults boolForKey:@"SmallView"];
    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
        id rowItem = [self itemAtRow:row];
        if (![rowItem isKindOfClass:[TorrentGroup class]])
        {
            if (minimal)
            {
                SmallTorrentCell* smallCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
                [(TorrentCellControlButton*)smallCell.fControlButton resetImage];
            }
            else
            {
                TorrentCell* torrentCell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
                [(TorrentCellControlButton*)torrentCell.fControlButton resetImage];
            }
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

static CGFloat const kPlayButtonRightMargin = 55.0;
static CGFloat const kPlayButtonRowHeight = 18.0;
static CGFloat const kPlayButtonVerticalPadding = 4.0;

- (CGFloat)outlineView:(NSOutlineView*)outlineView heightOfRowByItem:(id)item
{
    if ([item isKindOfClass:[Torrent class]])
    {
        Torrent* torrent = (Torrent*)item;
        CGFloat height = self.rowHeight;

        // Adjust height for play buttons if present and enabled
        if (!self.fSmallView && [self.fDefaults boolForKey:@"ShowContentButtons"] && torrent.cachedPlayButtonsHeight > height)
        {
            height = torrent.cachedPlayButtonsHeight;
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

            // Static content - only update when torrent changes
            if (!sameTorrentMinimal)
            {
                torrentCell.fTorrentHash = torrentHash;
                torrentCell.fIconView.image = error ? [NSImage imageNamed:NSImageNameCaution] : torrent.icon;
                torrentCell.fTorrentTitleField.stringValue = torrent.displayName;
            }

            // fix: hide play buttons in minimal mode
            if (torrentCell.fPlayButtonsView)
            {
                torrentCell.fPlayButtonsView.hidden = YES;
            }

            // Dynamic content - always update
            torrentCell.fTorrentStatusField.stringValue = self.fDisplaySmallStatusRegular ? torrent.shortStatusString :
                                                                                            torrent.remainingTimeString;

            if (self.fHoverEventDict)
            {
                NSInteger row = [self rowForItem:item];
                NSInteger hoverRow = [self.fHoverEventDict[@"row"] integerValue];

                if (row == hoverRow)
                {
                    torrentCell.fTorrentStatusField.hidden = YES;
                    torrentCell.fControlButton.hidden = NO;
                    torrentCell.fRevealButton.hidden = NO;
                    torrentCell.fURLButton.hidden = (torrent.commentURL == nil);
                }
            }
            else
            {
                torrentCell.fTorrentStatusField.hidden = NO;
                torrentCell.fControlButton.hidden = YES;
                torrentCell.fRevealButton.hidden = YES;
                torrentCell.fURLButton.hidden = YES;
            }
        }
        else
        {
            torrentCell = [outlineView makeViewWithIdentifier:@"TorrentCell" owner:self];
            BOOL const sameTorrentFull = [torrentCell.fTorrentHash isEqualToString:torrentHash];

            // Static content - only update when torrent changes
            if (!sameTorrentFull)
            {
                torrentCell.fTorrentHash = torrentHash;

                // set torrent icon and error badge
                NSImage* fileImage = torrent.icon;
                if (error)
                {
                    NSRect frame = torrentCell.fIconView.frame;
                    NSImage* resultImage = [[NSImage alloc] initWithSize:NSMakeSize(frame.size.width, frame.size.height)];
                    [resultImage lockFocus];

                    // draw fileImage
                    [fileImage drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];

                    // overlay error badge
                    NSImage* errorImage = [NSImage imageNamed:NSImageNameCaution];
                    NSRect const errorRect = NSMakeRect(0, 0, kErrorImageSize, kErrorImageSize);
                    [errorImage drawInRect:errorRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
                            respectFlipped:YES
                                     hints:nil];

                    [resultImage unlockFocus];

                    torrentCell.fIconView.image = resultImage;
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

            // set URL button visibility
            torrentCell.fURLButton.hidden = (torrent.commentURL == nil);

            // show status, control, reveal and icon buttons (they might have been hidden in minimal mode)
            torrentCell.fTorrentStatusField.hidden = NO;
            torrentCell.fControlButton.hidden = NO;
            torrentCell.fRevealButton.hidden = NO;
            torrentCell.fIconView.hidden = NO;

            // Dynamic content - always update
            NSString* progressString = torrent.progressString;
            if (![torrentCell.fTorrentProgressField.stringValue isEqualToString:progressString])
            {
                torrentCell.fTorrentProgressField.stringValue = progressString;
            }

            // configure/update play buttons for media torrents
            // (must be in dynamic section to handle playableFiles becoming available after initial setup)
            [self configurePlayButtonsForCell:torrentCell torrent:torrent];

            // set torrent status
            NSString* status;
            if (self.fHoverEventDict)
            {
                NSInteger row = [self rowForItem:item];
                NSInteger hoverRow = [self.fHoverEventDict[@"row"] integerValue];

                if (row == hoverRow)
                {
                    status = self.fHoverEventDict[@"string"];
                }
            }
            NSString* statusString = status ?: torrent.statusString;
            if (![torrentCell.fTorrentStatusField.stringValue isEqualToString:statusString])
            {
                torrentCell.fTorrentStatusField.stringValue = statusString;
            }
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
    self.fSelectedRowIndexes = self.selectedRowIndexes;
    [self reloadVisibleRows];
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
            {
                Torrent* torrent = (Torrent*)item;
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
                else
                {
                    [self.fController showInfo:nil];
                }
            }
            else
            {
                [self.fController showInfo:nil];
            }
        }
        else
        {
            if ([self isItemExpanded:item])
            {
                [self collapseItem:item];
            }
            else
            {
                [self expandItem:item];
            }
        }
    }
    else if ([self pointInGroupStatusRect:point])
    {
        //we check for this here rather than in the GroupCell
        //as using floating group rows causes all sorts of weirdness...
        [self toggleGroupRowRatio];
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

- (void)playContextItem:(NSMenuItem*)sender
{
    NSDictionary* represented = sender.representedObject;
    Torrent* torrent = represented[@"torrent"];
    NSDictionary* item = represented[@"item"];
    if (torrent && item)
    {
        [self playMediaItem:item forTorrent:torrent];
    }
}

- (NSImage*)iconForPlayableFileItem:(NSDictionary*)fileItem
{
    if (@available(macOS 11.0, *))
    {
        NSString* type = fileItem[@"type"] ?: @"file";
        NSString* category = fileItem[@"category"];
        
        // Cache key based on type and category
        NSString* cacheKey = [NSString stringWithFormat:@"%@:%@", type, category ?: @""];
        NSImage* cached = [self.fIconCache objectForKey:cacheKey];
        if (cached)
            return cached;

        NSString* symbolName = nil;

        if ([type isEqualToString:@"document-books"] || [category isEqualToString:@"books"])
        {
            symbolName = @"book";  // Outlined book for documents
        }
        else if ([type isEqualToString:@"album"])
        {
            symbolName = @"music.note.list";  // Double note for albums
        }
        else if ([type isEqualToString:@"track"] || [category isEqualToString:@"audio"])
        {
            symbolName = @"music.note";  // Single note for tracks/audio
        }
        else if ([type isEqualToString:@"dvd"] || [type isEqualToString:@"bluray"] || [category isEqualToString:@"video"])
        {
            symbolName = @"play";  // Outlined triangle for video
        }

        if (symbolName)
        {
            NSImage* icon = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
            if (icon)
                [self.fIconCache setObject:icon forKey:cacheKey];
            return icon;
        }
    }
    return nil;
}

- (NSArray<NSDictionary*>*)tracksForAlbumItem:(NSDictionary*)albumItem torrent:(Torrent*)torrent
{
    NSString* folder = albumItem[@"folder"];
    if (!folder || folder.length == 0)
        return nil;
    
    NSIndexSet* fileIndexes = [torrent fileIndexesForFolder:folder];
    if (!fileIndexes || fileIndexes.count == 0)
        return nil;
    
    static NSSet<NSString*>* audioExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExtensions = [NSSet setWithArray:@[
            @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus"
        ]];
    });
    
    NSMutableArray<NSDictionary*>* tracks = [NSMutableArray array];
    [fileIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* _Nonnull stop) {
        (void)stop;
        auto const file = tr_torrentFile(torrent.torrentStruct, (tr_file_index_t)idx);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;
        
        // Only include audio files, skip .cue files
        if (![audioExtensions containsObject:ext])
            return;
        
        CGFloat progress = (CGFloat)tr_torrentFileConsecutiveProgress(torrent.torrentStruct, (tr_file_index_t)idx);
        if (progress < 0)
            progress = 0;
        
        // Visibility logic: only show tracks that have started downloading.
        // If the file is not wanted, only show it if it's 100% complete.
        if (progress <= 0 && file.wanted)
            return;
        if (!file.wanted && progress < 1.0)
            return;
        
        NSString* displayName = fileName.lastPathComponent.stringByDeletingPathExtension.humanReadableFileName;
        if (!displayName || displayName.length == 0)
            displayName = fileName.lastPathComponent;
        
        // Cache humanized name back to torrent? No, tracks are recreated.
        // We can use an associated object on the torrent's file indexes if needed, 
        // but let's just make it faster for now.
        
        auto const location = tr_torrentFindFile(torrent.torrentStruct, (tr_file_index_t)idx);
        NSString* path = !std::empty(location) ? @(location.c_str()) : 
                        [torrent.currentDirectory stringByAppendingPathComponent:fileName];
        
        [tracks addObject:@{
            @"type": @"track",
            @"category": @"audio",
            @"index": @(idx),
            @"name": displayName,
            @"path": path,
            @"progress": @(progress)
        }];
    }];
    
    // Sort tracks alphabetically (they should already be in order, but just to be sure)
    [tracks sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    
    return tracks.count > 0 ? tracks : nil;
}

- (NSMenu*)playMenuForTorrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        return nil;
    }

    NSUInteger statsGeneration = torrent.statsGeneration;
    NSMenu* cachedMenu = [self.fPlayMenuCache objectForKey:torrent];
    if (cachedMenu && torrent.cachedPlayMenuGeneration == statsGeneration)
    {
        return cachedMenu;
    }

    BOOL const isBooks = [torrent.detectedMediaCategory isEqualToString:@"books"];
    NSString* mainTitle = isBooks ? NSLocalizedString(@"Read", "Context menu") : NSLocalizedString(@"Play", "Context menu");

    NSMenu* menu = [[NSMenu alloc] initWithTitle:mainTitle];
    menu.delegate = self;

    NSArray<NSDictionary*>* state = [self playButtonStateForTorrent:torrent];
    NSArray<NSDictionary*>* layout = [self playButtonLayoutForTorrent:torrent state:state];

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
            NSString* name = fileItem[@"name"] ?: @"";
            CGFloat progress = [fileItem[@"progress"] doubleValue];
            
            NSString* menuTitle = name;
            if (progress > 0 && progress < 1.0)
            {
                int progressPct = (int)floor(progress * 100);
                if (progressPct < 100)
                    menuTitle = [NSString stringWithFormat:@"%@ (%d%%)", name, progressPct];
            }

            // For albums, check if we can expand to individual tracks
            if ([type isEqualToString:@"album"])
            {
                NSArray<NSDictionary*>* tracks = [self tracksForAlbumItem:fileItem torrent:torrent];
                if (tracks && tracks.count > 1)
                {
                    // Create submenu for album with individual tracks
                    NSMenuItem* albumItem = [[NSMenuItem alloc] initWithTitle:menuTitle action:nil keyEquivalent:@""];
                    albumItem.image = [self iconForPlayableFileItem:fileItem];
                    NSMenu* albumMenu = [[NSMenu alloc] initWithTitle:menuTitle];
                    albumMenu.delegate = self;
                    albumItem.submenu = albumMenu;

                    // Add individual tracks to submenu
                    for (NSDictionary* track in tracks)
                    {
                        NSString* trackName = track[@"name"];
                        CGFloat trackProgress = [track[@"progress"] doubleValue];
                        NSString* trackTitle = trackName;
                        if (trackProgress > 0 && trackProgress < 1.0)
                        {
                            int trackPct = (int)floor(trackProgress * 100);
                            if (trackPct < 100)
                                trackTitle = [NSString stringWithFormat:@"%@ (%d%%)", trackName, trackPct];
                        }

                        NSMenuItem* trackItem = [[NSMenuItem alloc] initWithTitle:trackTitle action:@selector(playContextItem:) keyEquivalent:@""];
                        trackItem.target = self;
                        trackItem.representedObject = @{ @"torrent": torrent, @"item": track };
                        trackItem.image = [self iconForPlayableFileItem:track];
                        [albumMenu addItem:trackItem];
                    }
                    
                    [currentMenu addItem:albumItem];
                    continue;
                }
            }
            
            // Regular item (file, single-track album, DVD, Blu-ray, book, etc.)
            NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle:menuTitle action:@selector(playContextItem:) keyEquivalent:@""];
            menuItem.target = self;
            menuItem.representedObject = @{ @"torrent" : torrent, @"item" : fileItem };

            menuItem.image = [self iconForPlayableFileItem:fileItem];

            [currentMenu addItem:menuItem];
        }
    }

    if (menu.numberOfItems == 0)
    {
        return nil;
    }

    [self.fPlayMenuCache setObject:menu forKey:torrent];
    torrent.cachedPlayMenuGeneration = statsGeneration;

    return menu;
}

- (void)updatePlayMenuForItem:(id)item
{
    // Remove old play items (tagged with 100)
    NSArray* items = [self.fContextRow.itemArray copy];
    for (NSMenuItem* existing in items)
    {
        if (existing.tag == 100)
        {
            [self.fContextRow removeItem:existing];
        }
    }

    if (![item isKindOfClass:[Torrent class]])
    {
        return;
    }

    Torrent* torrent = (Torrent*)item;
    NSMenu* playMenu = [self playMenuForTorrent:torrent];
    if (!playMenu)
    {
        return;
    }

    BOOL const isAudio = [torrent.detectedMediaCategory isEqualToString:@"audio"];
    BOOL const isBooks = [torrent.detectedMediaCategory isEqualToString:@"books"];
    NSImage* icon = nil;
    if (@available(macOS 11.0, *))
    {
        // Use double note for audio (albums), book for documents, smaller play triangle for video
        icon = [NSImage imageWithSystemSymbolName:(isBooks ? @"book" : (isAudio ? @"music.note.list" : @"play")) accessibilityDescription:nil];
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
        NSDictionary* data = item.representedObject;
        Torrent* torrent = data[@"torrent"];
        NSDictionary* fileItem = data[@"item"];
        if (torrent && fileItem)
        {
            [self setHighPriorityForItem:fileItem forTorrent:torrent];
        }
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

    // Only reload the specific row instead of all visible rows
    [self reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
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
        // Only reload the specific row instead of all visible rows
        [self reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
}

- (void)toggleGroupRowRatio
{
    BOOL displayGroupRowRatio = self.fDisplayGroupRowRatio;
    [self.fDefaults setBool:!displayGroupRowRatio forKey:@"DisplayGroupRowRatio"];
    [self updateDefaultsCache];
    [self reloadVisibleRows];
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

- (IBAction)revealTorrentFile:(id)sender
{
    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    NSString* location = torrent.dataLocation;
    if (location)
    {
        NSURL* file = [NSURL fileURLWithPath:location];
        if (torrent.folder)
        {
            // Folder torrent - open the folder to show its contents
            [NSWorkspace.sharedWorkspace openURL:file];
        }
        else
        {
            // Single file torrent - reveal/select it in Finder
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ file ]];
        }
    }
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

/// Creates a play button from playable item info
/// Item types: "file", "dvd", "bluray", "album"
- (PlayButton*)createPlayButtonFromItem:(NSDictionary*)item
{
    NSString* type = item[@"type"] ?: @"file";
    NSString* path = item[@"path"];
    NSString* baseTitle = item[@"baseTitle"];
    CGFloat progress = [item[@"progress"] doubleValue];

    // Build button title with progress
    NSString* title = item[@"title"];
    if (!title)
    {
        if ([type hasPrefix:@"document"])
            title = baseTitle;
        else if (progress > 0 && progress < 1.0)
            title = [NSString stringWithFormat:@"%@ (%d%%)", baseTitle, (int)floor(progress * 100)];
        else
            title = baseTitle;
    }

    PlayButton* playButton = [[PlayButton alloc] init];
    playButton.title = title;
    playButton.image = [self iconForPlayableFileItem:item];
    playButton.imagePosition = NSImageLeft;
    playButton.target = self;
    playButton.action = @selector(playMediaFile:);
    __weak TorrentTableView* weakSelf = self;
    playButton.onHover = ^(PlayButton* button) {
        [weakSelf setHighPriorityForButton:button];
    };
    playButton.bezelStyle = NSBezelStyleRecessed;
    playButton.showsBorderOnlyWhileMouseInside = YES;
    playButton.font = [NSFont systemFontOfSize:11];
    playButton.controlSize = NSControlSizeSmall;
    playButton.toolTip = path;
    playButton.identifier = path;

    // Store type for playback handling, base title for updates
    playButton.accessibilityHelp = type;
    playButton.accessibilityLabel = baseTitle;

    // For files, store index for progress updates; folders use NSNotFound
    NSNumber* index = item[@"index"];
    playButton.tag = index ? index.integerValue : NSNotFound;
    NSString* folder = item[@"folder"];
    if (folder.length > 0)
    {
        objc_setAssociatedObject(playButton, @selector(folderForPlayButton:), folder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Hide until download starts (or completion for documents)
    NSNumber* visible = item[@"visible"];
    if (visible != nil)
    {
        playButton.hidden = !visible.boolValue;
    }
    else if ([type hasPrefix:@"document"])
    {
        playButton.hidden = (progress < 1.0);
    }
    else
    {
        playButton.hidden = (progress <= 0);
    }

    return playButton;
}

static id playButtonFolderCache(NSButton* sender)
{
    return objc_getAssociatedObject(sender, @selector(folderForPlayButton:));
}

static void setPlayButtonFolderCache(NSButton* sender, id value)
{
    objc_setAssociatedObject(sender, @selector(folderForPlayButton:), value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString* folderForPlayButton(NSButton* sender, Torrent* torrent)
{
    id cached = playButtonFolderCache(sender);
    if ([cached isKindOfClass:[NSString class]])
    {
        return (NSString*)cached;
    }
    if (cached == [NSNull null])
    {
        return nil;
    }

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

- (NSMutableArray<NSMutableDictionary*>*)playButtonStateForTorrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        torrent.cachedPlayButtonSource = nil;
        torrent.cachedPlayButtonState = nil;
        torrent.cachedPlayButtonLayout = nil;
        return nil;
    }

    BOOL isSameSource = [torrent.cachedPlayButtonSource isEqualToArray:playableFiles];
    if (!isSameSource)
    {
        torrent.cachedPlayButtonSource = playableFiles;
        torrent.cachedPlayButtonState = nil;
        torrent.cachedPlayButtonLayout = nil;
        torrent.cachedPlayButtonProgressGeneration = 0;
    }

    NSMutableArray<NSMutableDictionary*>* state = (NSMutableArray<NSMutableDictionary*>*)torrent.cachedPlayButtonState;
    if (!state)
    {
        state = [NSMutableArray arrayWithCapacity:playableFiles.count];
        BOOL singleItem = playableFiles.count == 1;

        for (NSDictionary* fileInfo in playableFiles)
        {
            NSMutableDictionary* entry = [fileInfo mutableCopy];
            NSString* type = entry[@"type"] ?: @"file";
            NSString* category = entry[@"category"];
            if (!category)
            {
                if ([type isEqualToString:@"file"] || [type hasPrefix:@"document"])
                {
                    category = [torrent mediaCategoryForFile:[entry[@"index"] unsignedIntegerValue]];
                }
                else
                {
                    category = ([type isEqualToString:@"album"]) ? @"audio" : @"video";
                }
                entry[@"category"] = category;
            }

            BOOL const itemIsBooks = [category isEqualToString:@"books"];
            (void)itemIsBooks; // Suppress unused variable warning

            if (singleItem)
            {
                entry[@"baseTitle"] = itemIsBooks ? @"Read" : @"Play";
            }
            else
            {
                // Multi-item: baseTitle humanized in Torrent.mm
                entry[@"baseTitle"] = entry[@"baseTitle"] ?: @"";
            }
            entry[@"title"] = entry[@"baseTitle"] ?: @"";
            entry[@"visible"] = @NO;
            entry[@"progress"] = @0.0;
            entry[@"progressPercent"] = @0;
            [state addObject:entry];
        }
        torrent.cachedPlayButtonState = state;
    }

    NSUInteger statsGeneration = torrent.statsGeneration;
    if (torrent.cachedPlayButtonProgressGeneration == statsGeneration)
    {
        return state;
    }

    BOOL visibilityChanged = NO;
    for (NSMutableDictionary* entry in state)
    {
        NSString* type = entry[@"type"] ?: @"file";
        NSNumber* index = entry[@"index"];
        CGFloat progress = [entry[@"progress"] doubleValue];
        BOOL wasVisible = [entry[@"visible"] boolValue];
        CGFloat newProgress = progress;
        if (index)
        {
            newProgress = [torrent fileProgressForIndex:index.unsignedIntegerValue];
        }
        else
        {
            NSString* folder = entry[@"folder"];
            newProgress = folder.length > 0 ? [torrent folderConsecutiveProgress:folder] : 0.0;
        }
        if (std::fabs(newProgress - progress) > 0.000001)
        {
            progress = newProgress;
            entry[@"progress"] = @(progress);
            int progressPct = (int)floor(progress * 100);
            entry[@"progressPercent"] = @(progressPct);
            BOOL visible = [type hasPrefix:@"document"] ? (progress >= 1.0) : (progress > 0);
            entry[@"visible"] = @(visible);
            if (visible != wasVisible)
            {
                visibilityChanged = YES;
            }
            NSString* baseTitle = entry[@"baseTitle"] ?: @"";
            NSString* title = baseTitle;
            if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
            {
                title = [NSString stringWithFormat:@"%@ (%d%%)", baseTitle, progressPct];
            }
            entry[@"title"] = title;
        }
    }

    if (visibilityChanged)
    {
        torrent.cachedPlayButtonLayout = nil;
    }

    torrent.cachedPlayButtonProgressGeneration = statsGeneration;
    return state;
}

- (NSArray<NSDictionary*>*)playButtonLayoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state
{
    if (torrent.cachedPlayButtonLayout != nil)
    {
        return torrent.cachedPlayButtonLayout;
    }

    if (state.count == 0)
    {
        return nil;
    }

    NSMutableArray<NSDictionary*>* layout = [NSMutableArray array];
    if (state.count == 1)
    {
        [layout addObject:@{ @"kind" : @"item", @"item" : state[0] }];
        torrent.cachedPlayButtonLayout = layout;
        return layout;
    }

    // For multiple items, only show them if at least one has started downloading
    // or if they are all finished. This prevents showing a single generic "Play"
    // button when multiple items are planned.
    BOOL anyVisible = NO;
    for (NSDictionary* entry in state)
    {
        if ([entry[@"visible"] boolValue])
        {
            anyVisible = YES;
            break;
        }
    }

    if (!anyVisible)
    {
        return nil;
    }

    NSMutableDictionary<NSNumber*, NSMutableArray<NSDictionary*>*>* seasonGroups = [NSMutableDictionary dictionary];
    for (NSDictionary* fileInfo in state)
    {
        id seasonValue = fileInfo[@"season"];
        NSNumber* season = (seasonValue && seasonValue != [NSNull null]) ? seasonValue : @0;
        if (!seasonGroups[season])
        {
            seasonGroups[season] = [NSMutableArray array];
        }
        [seasonGroups[season] addObject:fileInfo];
    }

    NSArray<NSNumber*>* sortedSeasons = [seasonGroups.allKeys sortedArrayUsingSelector:@selector(compare:)];
    BOOL hasMultipleSeasons = sortedSeasons.count > 1;

    NSUInteger totalFilesShown = 0;
    NSUInteger const maxFiles = 100;

    for (NSNumber* season in sortedSeasons)
    {
        if (totalFilesShown >= maxFiles)
            break;

        NSArray<NSDictionary*>* filesInSeason = seasonGroups[season];

        if (hasMultipleSeasons && season.integerValue > 0)
        {
            NSString* title = [NSString stringWithFormat:@"Season %@:", season];
            [layout addObject:@{ @"kind" : @"header", @"title" : title }];
        }

        for (NSDictionary* fileInfo in filesInSeason)
        {
            if (totalFilesShown >= maxFiles)
                break;
            [layout addObject:@{ @"kind" : @"item", @"item" : fileInfo }];
            totalFilesShown++;
        }
    }

    torrent.cachedPlayButtonLayout = layout;
    return layout;
}

- (CGFloat)playButtonsAvailableWidthForCell:(TorrentCell*)cell
{
    CGFloat tableWidth = NSWidth(self.bounds);
    CGFloat leadingX = NSMinX(cell.fTorrentStatusField.frame);
    CGFloat availableWidth = tableWidth - leadingX - kPlayButtonRightMargin - self.intercellSpacing.width;
    return MAX((CGFloat)200.0, availableWidth);
}

- (void)configurePlayButtonsForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    // Check if content buttons should be shown
    if (![self.fDefaults boolForKey:@"ShowContentButtons"])
    {
        // Remove existing buttons if hidden
        if (cell.fPlayButtonsView)
        {
            [cell.fPlayButtonsView removeFromSuperview];
            cell.fPlayButtonsView = nil;
            cell.fPlayButtonsSourceFiles = nil;
            cell.fPlayButtonsHeightConstraint = nil;
        }
        return;
    }

    NSArray<NSDictionary*>* playButtonState = [self playButtonStateForTorrent:torrent];
    NSArray<NSDictionary*>* playButtonLayout = [self playButtonLayoutForTorrent:torrent state:playButtonState];

    // Reuse existing buttons if same torrent/files
    if (cell.fPlayButtonsView && [cell.fPlayButtonsSourceFiles isEqualToArray:playButtonState])
    {
        cell.fPlayButtonsView.hidden = NO;
        // Only update progress for finished torrents that might have just completed
        [self updatePlayButtonProgressForCell:cell torrent:torrent];
        return;
    }

    // Remove existing buttons (cell is being reused for different torrent)
    if (cell.fPlayButtonsView)
    {
        [cell.fPlayButtonsView removeFromSuperview];
        cell.fPlayButtonsView = nil;
        cell.fPlayButtonsSourceFiles = nil;
        cell.fPlayButtonsHeightConstraint = nil;
    }

    if (!playButtonLayout || playButtonLayout.count == 0)
        return;

    FlowLayoutView* flowView = [[FlowLayoutView alloc] init];
    flowView.translatesAutoresizingMaskIntoConstraints = NO;
    flowView.horizontalSpacing = 6;
    flowView.verticalSpacing = 4;
    flowView.minimumButtonWidth = 50;

    for (NSDictionary* entry in playButtonLayout)
    {
        NSString* kind = entry[@"kind"];
        if ([kind isEqualToString:@"header"])
        {
            [flowView addLineBreak];
            NSTextField* seasonLabel = [NSTextField labelWithString:entry[@"title"] ?: @""];
            seasonLabel.font = [NSFont boldSystemFontOfSize:11];
            seasonLabel.textColor = NSColor.secondaryLabelColor;
            [flowView addArrangedSubview:seasonLabel];
        }
        else
        {
            NSDictionary* item = entry[@"item"];
            if (item)
            {
                [flowView addArrangedSubview:[self createPlayButtonFromItem:item]];
            }
        }
    }

    // Add to cell first so we can use constraints
    flowView.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:flowView];
    cell.fPlayButtonsView = flowView;
    cell.fPlayButtonsSourceFiles = playButtonState;

    CGFloat rightMargin = kPlayButtonRightMargin; // Space for control buttons

    // Constraints: position below status field
    cell.fPlayButtonsHeightConstraint = [flowView.heightAnchor constraintEqualToConstant:1.0];
    [NSLayoutConstraint activateConstraints:@[
        [flowView.leadingAnchor constraintEqualToAnchor:cell.fTorrentStatusField.leadingAnchor],
        [flowView.topAnchor constraintEqualToAnchor:cell.fTorrentStatusField.bottomAnchor constant:kPlayButtonVerticalPadding],
        [flowView.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-rightMargin],
        cell.fPlayButtonsHeightConstraint
    ]];

    // Get actual height from flow view using resolved width
    CGFloat availableWidth = [self playButtonsAvailableWidthForCell:cell];

    // Update button progress/visibility with fresh values (cached playableFiles may have stale progress)
    [self updatePlayButtonProgressForCell:cell torrent:torrent];

    // Always recalculate height based on visible buttons
    CGFloat buttonHeight = [flowView heightForWidth:availableWidth];
    BOOL hasVisibleButtons = buttonHeight > 0;
    if (hasVisibleButtons && buttonHeight < kPlayButtonRowHeight)
        buttonHeight = kPlayButtonRowHeight;

    cell.fPlayButtonsHeightConstraint.constant = buttonHeight;

    CGFloat totalHeight = self.rowHeight + (hasVisibleButtons ? (buttonHeight + kPlayButtonVerticalPadding) : 0);
    CGFloat oldHeight = torrent.cachedPlayButtonsHeight;
    torrent.cachedPlayButtonsHeight = totalHeight;
    torrent.cachedPlayButtonsWidth = availableWidth;

    // Notify table if height changed (dispatch to avoid layout issues during cell configuration)
    if (fabs(totalHeight - oldHeight) > 1.0)
    {
        NSInteger row = [self rowForItem:torrent];
        if (row >= 0)
        {
            NSIndexSet* indexSet = [NSIndexSet indexSetWithIndex:row];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self noteHeightOfRowsWithIndexesChanged:indexSet];
            });
        }
    }
}

- (void)updatePlayButtonProgressForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    if (!cell.fPlayButtonsView || ![cell.fPlayButtonsView isKindOfClass:[FlowLayoutView class]])
        return;

    NSArray<NSDictionary*>* state = [self playButtonStateForTorrent:torrent];
    if (state.count == 0)
        return;

    BOOL layoutNeeded = NO;
    NSUInteger stateIndex = 0;
    for (NSView* view in [(FlowLayoutView*)cell.fPlayButtonsView arrangedSubviews])
    {
        if (![view isKindOfClass:[PlayButton class]])
            continue;

        if (stateIndex >= state.count)
            break;
        PlayButton* button = (PlayButton*)view;
        NSDictionary* entry = state[stateIndex++];
        NSNumber* visible = entry[@"visible"];
        NSString* title = entry[@"title"];
        if (visible && title)
        {
            if (button.hidden == visible.boolValue)
            {
                button.hidden = !visible.boolValue;
                layoutNeeded = YES;
            }

            if (![button.title isEqualToString:title])
            {
                button.title = title;
                [button invalidateIntrinsicContentSize];
                [(FlowLayoutView*)cell.fPlayButtonsView invalidateSizeForView:button];
                layoutNeeded = YES;
            }
        }
    }

    if (layoutNeeded)
    {
        FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
        [flowView invalidateLayoutCache];
        [flowView setNeedsLayout:YES];
        [flowView layoutSubtreeIfNeeded];

        // Recalculate height and update row
        CGFloat availableWidth = [self playButtonsAvailableWidthForCell:cell];
        CGFloat buttonHeight = [flowView heightForWidth:availableWidth];
        BOOL hasVisibleButtons = buttonHeight > 0;
        if (hasVisibleButtons && buttonHeight < kPlayButtonRowHeight)
            buttonHeight = kPlayButtonRowHeight;

        if (cell.fPlayButtonsHeightConstraint)
            cell.fPlayButtonsHeightConstraint.constant = buttonHeight;

        CGFloat totalHeight = self.rowHeight + (hasVisibleButtons ? (buttonHeight + kPlayButtonVerticalPadding) : 0);
        CGFloat oldHeight = torrent.cachedPlayButtonsHeight;
        torrent.cachedPlayButtonsHeight = totalHeight;
        torrent.cachedPlayButtonsWidth = availableWidth;

        // Notify table if height changed (dispatch to avoid layout issues during animation)
        if (fabs(totalHeight - oldHeight) > 1.0)
        {
            NSInteger row = [self rowForItem:torrent];
            if (row >= 0)
            {
                NSIndexSet* indexSet = [NSIndexSet indexSetWithIndex:row];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self noteHeightOfRowsWithIndexesChanged:indexSet];
                });
            }
        }
    }
}

- (NSIndexSet*)targetFileIndexesForPlayButton:(NSButton*)sender torrent:(Torrent*)torrent isComplete:(BOOL*)isComplete
{
    NSInteger fileIndex = sender.tag;
    if (fileIndex != NSNotFound)
    {
        if (isComplete != NULL)
            *isComplete = ([torrent fileProgressForIndex:fileIndex] >= 1.0);
        return [NSIndexSet indexSetWithIndex:fileIndex];
    }

    NSString* folder = folderForPlayButton(sender, torrent);
    NSIndexSet* fileIndexes = folder.length > 0 ? [torrent fileIndexesForFolder:folder] : nil;
    if (isComplete != NULL)
        *isComplete = (fileIndexes.count == 0) || (folder.length == 0) || ([torrent folderConsecutiveProgress:folder] >= 1.0);

    return fileIndexes;
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

    // Find the best file to play:
    // 1. First file that has started downloading (progress > 0)
    // 2. First file in the list
    NSDictionary* bestItem = nil;
    for (NSDictionary* item in playableFiles)
    {
        if ([item[@"progress"] doubleValue] > 0)
        {
            bestItem = item;
            break;
        }
    }

    if (!bestItem)
    {
        bestItem = playableFiles.firstObject;
    }

    if (bestItem)
    {
        [self playMediaItem:bestItem forTorrent:torrent];
    }
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

    NSIndexSet* otherHighIndexes = [self otherHighPriorityIndexesForTorrent:torrent excluding:targetIndexes];
    if (otherHighIndexes.count > 0)
    {
        NSIndexSet* normalIndexes = [self fileIndexesWithPriority:TR_PRI_NORMAL torrent:torrent];
        if (normalIndexes.count > 0)
            [torrent setFilePriority:TR_PRI_LOW forIndexes:normalIndexes];
        [torrent setFilePriority:TR_PRI_NORMAL forIndexes:otherHighIndexes];
    }

    [torrent setFilePriority:TR_PRI_HIGH forIndexes:targetIndexes];
}

- (void)playMediaItem:(NSDictionary*)item forTorrent:(Torrent*)torrent
{
    [self setHighPriorityForItem:item forTorrent:torrent];

    // Update last played date for the torrent
    tr_torrentSetLastPlayedDate(torrent.torrentStruct, time(nullptr));

    NSString* path = item[@"path"];
    if (!path)
        return;

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
    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    if (!torrent)
        return;

    NSDictionary* item = @{ @"index" : @(sender.tag), @"folder" : folderForPlayButton(sender, torrent) ?: @"" };

    [self setHighPriorityForItem:item forTorrent:torrent];
}

- (IBAction)playMediaFile:(NSButton*)sender
{
    Torrent* torrent = [self itemAtRow:[self rowForView:[sender superview]]];
    if (!torrent)
        return;

    NSDictionary* item = @{
        @"path" : sender.identifier ?: @"",
        @"type" : sender.accessibilityHelp ?: @"",
        @"index" : @(sender.tag),
        @"folder" : folderForPlayButton(sender, torrent) ?: @""
    };

    [self playMediaItem:item forTorrent:torrent];
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
