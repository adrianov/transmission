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
#import <objc/runtime.h>

static char const kFlowViewTorrentHashKey = '\0';
extern char const kPlayButtonTypeKey;
extern char const kPlayButtonFolderKey;
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
    [cell addSubview:cached];
    cell.fPlayButtonsView = cached;
    cell.fPlayButtonsSourceFiles = playableFiles;
    setFlowViewTorrentHash(cached, torrent.hashString);
    cell.fPlayButtonsHeightConstraint = [cached.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [cached.leadingAnchor constraintEqualToAnchor:cell.fTorrentStatusField.leadingAnchor],
        [cached.topAnchor constraintEqualToAnchor:cell.fTorrentStatusField.bottomAnchor constant:kFlowPlayButtonVerticalPadding],
        [cached.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-kFlowPlayButtonRightMargin],
        cell.fPlayButtonsHeightConstraint
    ]];
    cached.hidden = NO;
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:YES];
    [cell layoutSubtreeIfNeeded];
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
    [cell addSubview:flowView];
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
    {
        button = [[PlayButton alloc] init];
        button.target = self;
        button.action = @selector(playMediaFile:);
    }
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

- (PlayButton*)setupPlayButtonWithItem:(NSDictionary*)item torrent:(Torrent*)torrent
{
    PlayButton* playButton = [self dequeuePlayButton];
    NSString* type = item[@"type"] ?: @"file";
    NSString* path = item[@"path"];
    NSString* baseTitle = [torrent displayNameForPlayableItem:item];
    CGFloat progress = [item[@"progress"] doubleValue];

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
    NSString* openLabel = [torrent openCountLabelForPlayableItem:item];
    playButton.title = title;
    playButton.identifier = path;
    NSString* folder = item[@"folder"];
    NSString* tooltipPath = [torrent tooltipPathForItemPath:path type:type folder:folder ?: @""];
    playButton.toolTip = openLabel.length > 0 ? [NSString stringWithFormat:@"%@\n%@", tooltipPath, openLabel] : tooltipPath;
    playButton.tag = [item[@"index"] integerValue];
    objc_setAssociatedObject(playButton, &kPlayButtonTypeKey, type, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(playButton, &kPlayButtonFolderKey, folder.length > 0 ? folder : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSNumber* visible = item[@"visible"];
    if (visible != nil)
        playButton.hidden = !visible.boolValue;
    else if ([type hasPrefix:@"document"])
        playButton.hidden = (progress < 1.0);
    else
        playButton.hidden = (progress <= 0);

    NSString* pathToOpen = [torrent pathToOpenForPlayableItem:item];
    BOOL const leadsToCue = pathToOpen.length > 0 && [pathToOpen.pathExtension.lowercaseString isEqualToString:@"cue"];
    NSImage* icon = nil;
    if (@available(macOS 11.0, *))
    {
        if (leadsToCue)
        {
            icon = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:nil];
            NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium
                                                                                                  scale:NSImageSymbolScaleSmall];
            icon = [icon imageWithSymbolConfiguration:config];
            [icon setTemplate:YES];
        }
    }
    if (!icon)
        icon = [self iconForPlayableFileItem:item torrent:torrent];
    playButton.image = icon;
    playButton.imagePosition = icon ? NSImageLeft : NSNoImage;
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
        cell.fPlayButtonsView.hidden = NO;
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
        [self recycleSubviewsFromFlowView:flowView];
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
    flowView.hidden = NO;
    if (layout.count > 0)
        [self.fFlowViewCache setObject:flowView forKey:currentHash];
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:YES];
    // Force layout so flow view gets bounds and sets button frames before draw (avoids empty button area).
    [cell layoutSubtreeIfNeeded];
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
                return;
            NSMutableArray* mutableState = (NSMutableArray*)state;
            [PlayButtonStateBuilder enrichStateWithIinaUnwatched:mutableState forTorrent:t];
            __weak TorrentTableView* weakTv = tv;
            [tv.fPendingFlowApplies addObject:^{
                TorrentTableView* strongTv = weakTv;
                if (!strongTv)
                    return;
                if (![c.fTorrentHash isEqualToString:t.hashString])
                    return;
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
            NSDictionary* entry = (button.tag != NSNotFound) ? stateMap[@(button.tag)] :
                                                               (stateMap[[self folderForPlayButton:button torrent:torrent]] ?: nil);
            if (entry)
            {
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
                    [attr addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:11] range:NSMakeRange(0, currentTitle.length)];
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
        [flowView invalidateLayoutCache];
        CGFloat const availableWidth = [self playButtonsAvailableWidthForCell:cell];
        CGFloat buttonHeight = [flowView heightForWidth:availableWidth];
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
        [flowView setNeedsDisplay:YES];
    }
}

@end
