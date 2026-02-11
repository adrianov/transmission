// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Content buttons (flow view) lifecycle: config, apply, progress update. Keeps TorrentTableView under line limit.

#import "CocoaCompatibility.h"
#import "FlowLayoutView.h"
#import "PlayButton.h"
#import "PlayButtonStateBuilder.h"
#import "Torrent.h"
#import "TorrentCell.h"
#import "TorrentTableView.h"
#import "TorrentTableViewPrivate.h"
#include <cmath>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static char const kFlowViewTorrentHashKey = '\0';
extern char const kPlayButtonTypeKey;
extern char const kPlayButtonFolderKey;
extern char const kPlayButtonRepresentedKey;
static CGFloat const kFlowPlayButtonRightMargin = 55.0;
static CGFloat const kFlowPlayButtonRowHeight = 18.0;
static CGFloat const kFlowPlayButtonVerticalPadding = 4.0;
static NSTimeInterval const kHeightFlushDelay = 0.1;

static dispatch_queue_t gFlowComputeQueue(void)
{
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("org.m0k.transmission.flowCompute", DISPATCH_QUEUE_CONCURRENT);
    });
    return q;
}

static void setFlowViewTorrentHash(FlowLayoutView* flowView, NSString* hash)
{
    objc_setAssociatedObject(flowView, &kFlowViewTorrentHashKey, hash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString* flowViewTorrentHash(FlowLayoutView* flowView)
{
    id obj = objc_getAssociatedObject(flowView, &kFlowViewTorrentHashKey);
    return [obj isKindOfClass:[NSString class]] ? (NSString*)obj : nil;
}

static NSDictionary* computeStateAndLayoutFromSnapshot(NSArray<NSDictionary*>* snapshot)
{
    return [PlayButtonStateBuilder stateAndLayoutFromSnapshot:snapshot];
}

@implementation TorrentTableView (Flow)

- (BOOL)cellNeedsContentButtonsConfigForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    if (![self showContentButtonsPref])
        return YES;
    if (!cell.fPlayButtonsView)
        return YES;
    NSString* hash = torrent.hashString;
    if (![flowViewTorrentHash((FlowLayoutView*)cell.fPlayButtonsView) isEqualToString:hash])
        return YES;
    NSArray* playable = torrent.playableFiles;
    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    NSUInteger buttonCount = [flowView arrangedSubviews].count;
    if (playable.count > 0 && buttonCount == 0)
        return YES;
    return NO;
}

- (NSDictionary*)buildFlowSnapshotForTorrent:(Torrent*)torrent
{
    return [PlayButtonStateBuilder buildSnapshotForTorrent:torrent];
}

- (NSMutableArray<NSMutableDictionary*>*)playButtonStateForTorrent:(Torrent*)torrent
{
    return [PlayButtonStateBuilder stateForTorrent:torrent];
}

- (NSArray<NSDictionary*>*)playButtonLayoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state
{
    return [PlayButtonStateBuilder layoutForTorrent:torrent state:state];
}

- (CGFloat)playButtonsAvailableWidthForCell:(TorrentCell*)cell
{
    CGFloat tableWidth = NSWidth(self.bounds);
    CGFloat leadingX = NSMinX(cell.fTorrentStatusField.frame);
    CGFloat availableWidth = tableWidth - leadingX - kFlowPlayButtonRightMargin - self.intercellSpacing.width;
    return MAX((CGFloat)200.0, availableWidth);
}

- (void)recycleSubviewsFromFlowView:(FlowLayoutView*)flowView
{
    if (!flowView)
        return;
    for (NSView* view in [flowView arrangedSubviews])
    {
        if ([view isKindOfClass:[PlayButton class]])
        {
            PlayButton* button = (PlayButton*)view;
            [button prepareForReuse];
            [self.fPlayButtonPool addObject:button];
        }
        else if ([view isKindOfClass:[NSTextField class]])
        {
            NSTextField* field = (NSTextField*)view;
            field.stringValue = @"";
            field.hidden = NO;
            [self.fHeaderPool addObject:field];
        }
    }
    [flowView removeAllArrangedSubviews];
    [flowView invalidateIntrinsicContentSize];
}

- (void)clearFlowViewFromCell:(TorrentCell*)cell
{
    if (!cell.fPlayButtonsView)
        return;
    [self recycleSubviewsFromFlowView:(FlowLayoutView*)cell.fPlayButtonsView];
    [cell.fPlayButtonsView removeFromSuperview];
    cell.fPlayButtonsView = nil;
    cell.fPlayButtonsSourceFiles = nil;
    cell.fPlayButtonsHeightConstraint = nil;
}

- (void)hideFlowViewAndResetRowHeightForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    if (flowView)
    {
        flowView.hidden = YES;
        if (cell.fPlayButtonsHeightConstraint)
            cell.fPlayButtonsHeightConstraint.constant = 0;
        cell.fPlayButtonsSourceFiles = nil;
        [self recycleSubviewsFromFlowView:flowView];
        [flowView invalidateIntrinsicContentSize];
    }
    if (torrent.cachedPlayButtonsHeight > 0.5)
    {
        torrent.cachedPlayButtonsHeight = 0;
        [self queueHeightUpdateForRow:[self rowForItem:torrent]];
    }
}

- (void)attachCachedFlowView:(FlowLayoutView*)cached
                      toCell:(TorrentCell*)cell
                     torrent:(Torrent*)torrent
               playableFiles:(NSArray*)playableFiles
{
    [cached removeFromSuperview];
    // Insert at back so status/progress text is never obscured by play buttons (fix for new transfers).
    NSView* refView = cell.subviews.firstObject ?: cell.fTorrentStatusField;
    [cell addSubview:cached positioned:NSWindowBelow relativeTo:refView];
    cell.fPlayButtonsView = cached;
    cell.fPlayButtonsSourceFiles = playableFiles;
    setFlowViewTorrentHash(cached, torrent.hashString);
    CGFloat savedHeight = cached.lastLayoutHeight > 0 ? cached.lastLayoutHeight : 0;
    cell.fPlayButtonsHeightConstraint = [cached.heightAnchor constraintEqualToConstant:savedHeight];
    [NSLayoutConstraint activateConstraints:@[
        [cached.leadingAnchor constraintEqualToAnchor:cell.fTorrentStatusField.leadingAnchor],
        [cached.topAnchor constraintEqualToAnchor:cell.fTorrentStatusField.bottomAnchor constant:kFlowPlayButtonVerticalPadding],
        [cached.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-kFlowPlayButtonRightMargin],
        cell.fPlayButtonsHeightConstraint
    ]];
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:YES];
    [cached layoutSubtreeIfNeeded];
    [cell layoutSubtreeIfNeeded];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    cached.hidden = NO;
    [CATransaction commit];
    [cell setBackgroundStyle:cell.backgroundStyle];
    [cached setNeedsDisplay:YES];
    [cell setNeedsDisplay:YES];
}

- (FlowLayoutView*)newFlowViewAddedToCell:(TorrentCell*)cell
{
    FlowLayoutView* flowView = [[FlowLayoutView alloc] init];
    flowView.translatesAutoresizingMaskIntoConstraints = NO;
    flowView.horizontalSpacing = 6;
    flowView.verticalSpacing = 4;
    flowView.minimumButtonWidth = 50;
    flowView.maximumColumnCount = 8;
    // Start hidden to prevent black rectangle while buttons are computed asynchronously.
    // Callers unhide after populating buttons.
    flowView.hidden = YES;
    // Insert at back so status/progress text is never obscured by play buttons (fix for new transfers).
    NSView* refView = cell.subviews.firstObject ?: cell.fTorrentStatusField;
    [cell addSubview:flowView positioned:NSWindowBelow relativeTo:refView];
    cell.fPlayButtonsView = flowView;
    cell.fPlayButtonsHeightConstraint = [flowView.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [flowView.leadingAnchor constraintEqualToAnchor:cell.fTorrentStatusField.leadingAnchor],
        [flowView.topAnchor constraintEqualToAnchor:cell.fTorrentStatusField.bottomAnchor constant:kFlowPlayButtonVerticalPadding],
        [flowView.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-kFlowPlayButtonRightMargin],
        cell.fPlayButtonsHeightConstraint
    ]];
    return flowView;
}

- (PlayButton*)dequeuePlayButton
{
    PlayButton* button = self.fPlayButtonPool.lastObject;
    if (button)
        [self.fPlayButtonPool removeLastObject];
    else
        button = [[PlayButton alloc] init];
    // Always set target/action so clicks and tooltips work after pool reuse or when cell is reconfigured.
    button.target = self;
    button.action = @selector(playContextItem:);
    return button;
}

- (NSTextField*)dequeueHeader
{
    NSTextField* field = self.fHeaderPool.lastObject;
    if (field)
        [self.fHeaderPool removeLastObject];
    else
    {
        field = [NSTextField labelWithString:@""];
        field.font = [NSFont boldSystemFontOfSize:11];
        field.wantsLayer = YES;
    }
    return field;
}

/// Applies path-derived UI (identifier, tooltip, icon, type/folder) so button stays correct after progress/visibility updates (e.g. .cue+.flac when download completes).
- (void)applyPathDerivedUIToPlayButton:(PlayButton*)playButton forEntry:(NSDictionary*)entry torrent:(Torrent*)torrent
{
    NSString* type = entry[@"type"] ?: @"file";
    NSString* path = entry[@"path"];
    NSString* folder = entry[@"folder"] ?: @"";
    if (path.length > 0)
        playButton.identifier = path;
    NSString* tooltipPath = [torrent tooltipPathForItemPath:path ?: @"" type:type folder:folder];
    NSString* openLabel = [torrent openCountLabelForPlayableItem:entry];
    NSString* tip = openLabel.length > 0 ? [NSString stringWithFormat:@"%@\n%@", tooltipPath, openLabel] : tooltipPath;
    if (tip.length == 0)
        tip = playButton.title.length > 0 ? playButton.title : NSLocalizedString(@"Play", "Play button tooltip fallback");
    playButton.toolTip = tip;
    objc_setAssociatedObject(playButton, &kPlayButtonTypeKey, type, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(playButton, &kPlayButtonFolderKey, folder.length > 0 ? folder : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary* represented = @{ @"torrent" : torrent, @"item" : entry };
    objc_setAssociatedObject(playButton, &kPlayButtonRepresentedKey, represented, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSImage* icon = [self iconForPlayableFileItem:entry torrent:torrent];
    playButton.image = icon;
    playButton.imagePosition = icon ? NSImageLeft : NSNoImage;
}

- (PlayButton*)setupPlayButtonWithItem:(NSDictionary*)item torrent:(Torrent*)torrent
{
    PlayButton* playButton = [self dequeuePlayButton];
    NSString* type = item[@"type"] ?: @"file";
    CGFloat progress = [item[@"progress"] doubleValue];
    playButton.title = [self menuTitleForPlayableItem:item torrent:torrent includeProgress:YES];
    playButton.tag = [item[@"index"] integerValue];
    [self applyPathDerivedUIToPlayButton:playButton forEntry:item torrent:torrent];

    NSNumber* visible = item[@"visible"];
    if (visible != nil)
        playButton.hidden = !visible.boolValue;
    else if ([type hasPrefix:@"document"])
        playButton.hidden = (progress < 1.0);
    else
        playButton.hidden = (progress <= 0);

    NSNumber* iinaUnwatchedNum = item[@"iinaUnwatched"];
    playButton.iinaUnwatched = iinaUnwatchedNum ? iinaUnwatchedNum.boolValue : NO;
    return playButton;
}

- (void)queueHeightUpdateForRow:(NSInteger)row
{
    if (row < 0)
        return;
    [self.fPendingHeightRows addIndex:row];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushHeightUpdates) object:nil];
    [self performSelector:@selector(flushHeightUpdates) withObject:nil afterDelay:kHeightFlushDelay];
}

- (void)flushHeightUpdates
{
    if (self.fPendingHeightRows.count == 0)
        return;
    [self noteHeightOfRowsWithIndexesChanged:self.fPendingHeightRows];
    [self.fPendingHeightRows removeAllIndexes];
}

/// When async apply is skipped because the cell was reused (e.g. during scroll), the row that displays this torrent has a different cell that never got buttons. Scheduling config for that cell fixes missing buttons. Do not remove this re-schedule or buttons will disappear in some rows while scrolling.
- (void)scheduleConfigurePlayButtonsForTorrentIfNeeded:(Torrent*)torrent
{
    if (!torrent || ![self showContentButtonsPref] || torrent.playableFiles.count == 0)
        return;
    NSInteger row = [self rowForItem:torrent];
    if (row < 0)
        return;
    NSView* cellView = [self viewAtColumn:0 row:row makeIfNecessary:NO];
    if (![cellView isKindOfClass:[TorrentCell class]])
        return;
    TorrentCell* cell = (TorrentCell*)cellView;
    if ([self cellNeedsContentButtonsConfigForCell:cell torrent:torrent])
        [self scheduleConfigurePlayButtonsForCell:cell torrent:torrent];
}

- (void)scheduleConfigurePlayButtonsForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    NSString* hash = torrent.hashString;
    __weak TorrentCell* weakCell = cell;
    __weak Torrent* weakTorrent = torrent;
    __weak TorrentTableView* weakSelf = self;
    void (^block)(void) = ^{
        TorrentCell* c = weakCell;
        Torrent* t = weakTorrent;
        TorrentTableView* tv = weakSelf;
        if (!c || !t || !tv)
            return;
        if ([c.fTorrentHash isEqualToString:hash])
            [tv configurePlayButtonsForCell:c torrent:t];
    };
    [self.fPendingFlowConfigs addObject:block];
    if (self.fPendingFlowConfigs.count == 1)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self drainOneFlowConfig];
        });
}

- (void)drainOneFlowConfig
{
    if (self.fPendingFlowConfigs.count == 0)
        return;
    void (^block)(void) = self.fPendingFlowConfigs.firstObject;
    [self.fPendingFlowConfigs removeObjectAtIndex:0];
    block();
    if (self.fPendingFlowConfigs.count > 0)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self drainOneFlowConfig];
        });
}

- (void)drainOneFlowApply
{
    if (self.fPendingFlowApplies.count == 0)
        return;
    void (^block)(void) = self.fPendingFlowApplies.firstObject;
    [self.fPendingFlowApplies removeObjectAtIndex:0];
    block();
    if (self.fPendingFlowApplies.count > 0)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self drainOneFlowApply];
        });
}

- (void)applyFlowStateToCell:(TorrentCell*)cell
                     torrent:(Torrent*)torrent
                       state:(NSArray<NSDictionary*>*)state
                      layout:(NSArray<NSDictionary*>*)layout
               playableFiles:(NSArray<NSDictionary*>*)playableFiles
{
    NSString* currentHash = torrent.hashString;
    torrent.cachedPlayButtonSource = playableFiles;
    torrent.cachedPlayButtonState = (NSMutableArray<NSMutableDictionary*>*)state;
    torrent.cachedPlayButtonLayout = layout;
    torrent.cachedPlayButtonProgressGeneration = torrent.statsGeneration;

    if (layout.count == 0)
    {
        cell.fPlayButtonsSourceFiles = playableFiles;
        [self hideFlowViewAndResetRowHeightForCell:cell torrent:torrent];
        return;
    }
    FlowLayoutView* existingFlowView = (FlowLayoutView*)cell.fPlayButtonsView;
    BOOL flowViewMatchesTorrent = existingFlowView && [flowViewTorrentHash(existingFlowView) isEqualToString:currentHash];
    BOOL const sameSource = (cell.fPlayButtonsSourceFiles == playableFiles);
    BOOL const hasLayout = (layout.count > 0);
    BOOL const hasExistingButtons = existingFlowView && [existingFlowView arrangedSubviews].count > 0;

    if (cell.fPlayButtonsView && [cell.fTorrentHash isEqualToString:currentHash] && flowViewMatchesTorrent && sameSource &&
        (!hasLayout || hasExistingButtons))
    {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        cell.fPlayButtonsView.hidden = NO;
        [CATransaction commit];
        CGFloat const availableWidth = [self playButtonsAvailableWidthForCell:cell];
        BOOL const widthChanged = std::fabs(availableWidth - torrent.cachedPlayButtonsWidth) > 5.0;
        [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:widthChanged];
        return;
    }
    if (existingFlowView && !flowViewMatchesTorrent)
    {
        NSString* existingHash = flowViewTorrentHash(existingFlowView);
        if (existingHash.length > 0 && [existingFlowView arrangedSubviews].count > 0)
            [self.fFlowViewCache setObject:existingFlowView forKey:existingHash];
        [existingFlowView removeFromSuperview];
        cell.fPlayButtonsView = nil;
        cell.fPlayButtonsHeightConstraint = nil;
        cell.fPlayButtonsSourceFiles = nil;
        existingFlowView = nil;
    }
    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    if (flowView)
    {
        // Hide during subview recycling to avoid momentary black rectangle while
        // the layer-backed view has no children (regression fix for scroll artifacts).
        flowView.hidden = YES;
        [self recycleSubviewsFromFlowView:flowView];
    }
    else
        flowView = [self newFlowViewAddedToCell:cell];
    setFlowViewTorrentHash(flowView, currentHash);
    cell.fPlayButtonsSourceFiles = playableFiles;
    if (layout.count > 0)
    {
        for (NSDictionary* entry in layout)
            [self addPlayButtonLayoutEntry:entry toFlowView:flowView torrent:torrent];
        [flowView finishBatchUpdates];
    }
    if (layout.count > 0)
        [self.fFlowViewCache setObject:flowView forKey:currentHash];
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:YES];
    // Layout before revealing so buttons have final frames when shown (avoids blank-then-expand flicker on scroll).
    [flowView layoutSubtreeIfNeeded];
    [cell layoutSubtreeIfNeeded];
    // Disable implicit layer animations to avoid odd expand/flicker when revealing.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    flowView.hidden = NO;
    [CATransaction commit];
    [cell setBackgroundStyle:cell.backgroundStyle];
    [flowView setNeedsDisplay:YES];
    [cell setNeedsDisplay:YES];
}

- (void)configurePlayButtonsForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    if (![self showContentButtonsPref])
    {
        [self clearFlowViewFromCell:cell];
        return;
    }
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        [self hideFlowViewAndResetRowHeightForCell:cell torrent:torrent];
        return;
    }
    NSString* currentHash = torrent.hashString;
    if (cell.fPlayButtonsView && cell.fTorrentHash.length > 0 && ![cell.fTorrentHash isEqualToString:currentHash])
    {
        FlowLayoutView* evicted = (FlowLayoutView*)cell.fPlayButtonsView;
        if ([evicted arrangedSubviews].count > 0)
            [self.fFlowViewCache setObject:evicted forKey:cell.fTorrentHash];
        [self clearFlowViewFromCell:cell];
    }
    FlowLayoutView* cached = [self.fFlowViewCache objectForKey:currentHash];
    if (cached)
    {
        [self.fFlowViewCache removeObjectForKey:currentHash];
        NSString* cachedHash = flowViewTorrentHash(cached);
        if (cachedHash.length > 0 && ![cachedHash isEqualToString:currentHash])
        {
            [self.fFlowViewCache setObject:cached forKey:cachedHash];
            cached = nil;
        }
        else if ([cached arrangedSubviews].count == 0)
            cached = nil;
    }
    if (cached)
    {
        [self attachCachedFlowView:cached toCell:cell torrent:torrent playableFiles:playableFiles];
        return;
    }
    NSDictionary* snapshotDict = [self buildFlowSnapshotForTorrent:torrent];
    if (!snapshotDict)
        return;
    NSArray* snapshot = snapshotDict[@"snapshot"];
    NSArray* playableFilesForApply = snapshotDict[@"playableFiles"];
    __weak TorrentCell* weakCell = cell;
    __weak Torrent* weakTorrent = torrent;
    __weak TorrentTableView* weakSelf = self;
    NSString* hashForApply = currentHash;
    dispatch_async(gFlowComputeQueue(), ^{
        NSDictionary* result = computeStateAndLayoutFromSnapshot(snapshot);
        NSMutableArray* state = result[@"state"];
        NSArray* layout = result[@"layout"];
        dispatch_async(dispatch_get_main_queue(), ^{
            TorrentCell* c = weakCell;
            Torrent* t = weakTorrent;
            TorrentTableView* tv = weakSelf;
            if (!c || !t || !tv)
                return;
            if (![c.fTorrentHash isEqualToString:hashForApply])
            {
                [tv scheduleConfigurePlayButtonsForTorrentIfNeeded:t];
                return;
            }
            NSMutableArray* mutableState = (NSMutableArray*)state;
            [PlayButtonStateBuilder enrichStateWithIinaUnwatched:mutableState forTorrent:t];
            __weak TorrentTableView* weakTv = tv;
            [tv.fPendingFlowApplies addObject:^{
                TorrentTableView* strongTv = weakTv;
                if (!strongTv)
                    return;
                if (![c.fTorrentHash isEqualToString:t.hashString])
                {
                    [strongTv scheduleConfigurePlayButtonsForTorrentIfNeeded:t];
                    return;
                }
                [strongTv applyFlowStateToCell:c torrent:t state:mutableState layout:layout playableFiles:playableFilesForApply];
            }];
            if (tv.fPendingFlowApplies.count == 1)
                dispatch_async(dispatch_get_main_queue(), ^{
                    [tv drainOneFlowApply];
                });
        });
    });
}

- (void)addPlayButtonLayoutEntry:(NSDictionary*)entry toFlowView:(FlowLayoutView*)flowView torrent:(Torrent*)torrent
{
    NSString* kind = entry[@"kind"];
    if ([kind isEqualToString:@"header"])
    {
        [flowView addLineBreakBatched];
        NSTextField* seasonLabel = [self dequeueHeader];
        seasonLabel.stringValue = entry[@"title"] ?: @"";
        [flowView addArrangedSubviewBatched:seasonLabel];
    }
    else
    {
        NSDictionary* item = entry[@"item"];
        if (item)
            [flowView addArrangedSubviewBatched:[self setupPlayButtonWithItem:item torrent:torrent]];
    }
}

- (void)refreshPlayButtonStateForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    if (cell.fPlayButtonsView)
        [self updatePlayButtonProgressForCell:cell torrent:torrent];
    else if ([self showContentButtonsPref] && torrent.playableFiles.count > 0)
        [self scheduleConfigurePlayButtonsForCell:cell torrent:torrent];
}

- (void)updatePlayButtonProgressForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:NO];
}

- (void)updatePlayButtonProgressForCell:(TorrentCell*)cell torrent:(Torrent*)torrent forceLayout:(BOOL)forceLayout
{
    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    if (!flowView || ![flowView isKindOfClass:[FlowLayoutView class]])
        return;
    NSArray<NSDictionary*>* state = [self playButtonStateForTorrent:torrent];
    if (state.count == 0)
    {
        flowView.hidden = YES;
        if (cell.fPlayButtonsHeightConstraint)
            cell.fPlayButtonsHeightConstraint.constant = 0;
        [flowView invalidateIntrinsicContentSize];
        if (torrent.cachedPlayButtonsHeight > 0.5)
        {
            torrent.cachedPlayButtonsHeight = 0;
            [self queueHeightUpdateForRow:[self rowForItem:torrent]];
        }
        return;
    }
    BOOL anyVisible = NO;
    for (NSDictionary* e in state)
    {
        if ([e[@"visible"] boolValue])
        {
            anyVisible = YES;
            break;
        }
    }
    NSUInteger playButtonCount = 0;
    for (NSView* v in [flowView arrangedSubviews])
    {
        if ([v isKindOfClass:[PlayButton class]])
            playButtonCount++;
    }
    if (anyVisible && playButtonCount == 0)
    {
        [self scheduleConfigurePlayButtonsForCell:cell torrent:torrent];
        return;
    }
    NSInteger row = [self rowForItem:torrent];
    NSMutableDictionary* stateMap = [NSMutableDictionary dictionaryWithCapacity:state.count];
    for (NSDictionary* entry in state)
    {
        NSNumber* index = entry[@"index"];
        if (index)
            stateMap[index] = entry;
        else
        {
            NSString* folder = entry[@"folder"];
            if (folder)
                stateMap[folder] = entry;
        }
    }
    BOOL layoutNeeded = forceLayout;
    NSView* currentLineBreak = nil;
    NSTextField* currentHeader = nil;
    BOOL anyButtonVisibleInSection = NO;
    Class const playButtonClass = [PlayButton class];
    Class const textFieldClass = [NSTextField class];

    for (NSView* view in [flowView arrangedSubviews])
    {
        if ([view isKindOfClass:textFieldClass])
        {
            if (currentHeader)
            {
                BOOL const headerHidden = !anyButtonVisibleInSection;
                if (currentHeader.hidden != headerHidden)
                {
                    currentHeader.hidden = headerHidden;
                    if (currentLineBreak)
                        currentLineBreak.hidden = headerHidden;
                    layoutNeeded = YES;
                }
            }
            currentHeader = (NSTextField*)view;
            anyButtonVisibleInSection = NO;
            continue;
        }
        if ([view isKindOfClass:playButtonClass])
        {
            PlayButton* button = (PlayButton*)view;
            NSDictionary* represented = objc_getAssociatedObject(button, &kPlayButtonRepresentedKey);
            NSDictionary* item = [represented isKindOfClass:[NSDictionary class]] ? represented[@"item"] : nil;
            NSDictionary* entry = nil;
            if (item)
            {
                NSNumber* idx = item[@"index"];
                NSString* folder = item[@"folder"];
                entry = idx ? stateMap[idx] : (folder.length > 0 ? stateMap[folder] : nil);
            }
            if (!entry)
                entry = (button.tag != NSNotFound) ? stateMap[@(button.tag)] :
                                                     (stateMap[[self folderForPlayButton:button torrent:torrent]] ?: nil);
            if (entry)
            {
                [self applyPathDerivedUIToPlayButton:button forEntry:entry torrent:torrent];
                NSNumber* visibleNum = entry[@"visible"];
                NSString* title = entry[@"title"];
                if (visibleNum && title)
                {
                    BOOL const shouldBeHidden = !visibleNum.boolValue;
                    if (button.hidden != shouldBeHidden)
                    {
                        button.hidden = shouldBeHidden;
                        layoutNeeded = YES;
                    }
                    if (!shouldBeHidden)
                        anyButtonVisibleInSection = YES;
                    if (![button.title isEqualToString:title])
                    {
                        button.title = title;
                        [button invalidateIntrinsicContentSize];
                        [flowView invalidateSizeForView:button];
                        layoutNeeded = YES;
                    }
                    NSNumber* iinaUnwatchedNum = entry[@"iinaUnwatched"];
                    BOOL iinaUnwatched = iinaUnwatchedNum ? iinaUnwatchedNum.boolValue : NO;
                    if (button.iinaUnwatched != iinaUnwatched)
                    {
                        button.iinaUnwatched = iinaUnwatched;
                        layoutNeeded = YES;
                    }
                    NSColor* titleColor = [PlayButton titleColorUnwatched:button.iinaUnwatched];
                    NSString* currentTitle = button.title ?: @"";
                    NSMutableAttributedString* attr = [[NSMutableAttributedString alloc] initWithString:currentTitle];
                    [attr addAttribute:NSForegroundColorAttributeName value:titleColor range:NSMakeRange(0, currentTitle.length)];
                    [attr addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:11]
                                 range:NSMakeRange(0, currentTitle.length)];
                    button.attributedTitle = attr;
                    [button setNeedsDisplay:YES];
                }
            }
            continue;
        }
        currentLineBreak = view;
    }
    if (currentHeader)
    {
        BOOL const headerHidden = !anyButtonVisibleInSection;
        if (currentHeader.hidden != headerHidden)
        {
            currentHeader.hidden = headerHidden;
            if (currentLineBreak)
                currentLineBreak.hidden = headerHidden;
            layoutNeeded = YES;
        }
    }
    if (layoutNeeded)
    {
        CGFloat const availableWidth = [self playButtonsAvailableWidthForCell:cell];
        BOOL useSavedHeight = [flowView hasValidLayoutForWidth:availableWidth] && flowView.lastLayoutHeight > 0;
        CGFloat buttonHeight = useSavedHeight ? flowView.lastLayoutHeight : [flowView heightForWidth:availableWidth];
        if (buttonHeight > 0 && buttonHeight < kFlowPlayButtonRowHeight)
            buttonHeight = kFlowPlayButtonRowHeight;
        if (cell.fPlayButtonsHeightConstraint)
            cell.fPlayButtonsHeightConstraint.constant = buttonHeight;
        CGFloat totalHeight = self.rowHeight + (buttonHeight > 0 ? (buttonHeight + kFlowPlayButtonVerticalPadding) : 0);
        CGFloat oldHeight = torrent.cachedPlayButtonsHeight;
        torrent.cachedPlayButtonsHeight = totalHeight;
        torrent.cachedPlayButtonsWidth = availableWidth;
        if (std::fabs(totalHeight - oldHeight) > 1.0)
        {
            [self queueHeightUpdateForRow:row];
            if (buttonHeight > 0)
                [self noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:(NSUInteger)row]];
        }
        if (!useSavedHeight)
            [flowView setNeedsDisplay:YES];
    }
}

@end
