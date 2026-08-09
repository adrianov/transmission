// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Content buttons (flow view): synchronous config, no cache. Simple and reliable.

#import "CocoaCompatibility.h"
#import "FlowLayoutView.h"
#import "PlayButton.h"
#import "PlayButtonStateBuilder.h"
#import "Torrent.h"
#import "TorrentCell.h"
#import "TorrentTableView.h"
#import "TorrentTableViewPrivate.h"
#import <objc/runtime.h>

static char const kFlowViewTorrentHashKey = '\0';
extern char const kPlayButtonTypeKey;
extern char const kPlayButtonFolderKey;
extern char const kPlayButtonRepresentedKey;
extern char const kPlayButtonPathUiTokenKey = '\0';
static CGFloat const kFlowPlayButtonRightMargin = 55.0;
static CGFloat const kFlowPlayButtonVerticalPadding = 4.0;
static NSTimeInterval const kHeightFlushDelay = 0.1;

static void setFlowViewTorrentHash(FlowLayoutView* flowView, NSString* hash)
{
    objc_setAssociatedObject(flowView, &kFlowViewTorrentHashKey, hash, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString* flowViewTorrentHash(FlowLayoutView* flowView)
{
    id obj = objc_getAssociatedObject(flowView, &kFlowViewTorrentHashKey);
    return [obj isKindOfClass:[NSString class]] ? (NSString*)obj : nil;
}

@implementation TorrentTableView (Flow)

- (BOOL)cellNeedsContentButtonsConfigForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    if (self.fSmallView || ![self showContentButtonsPref])
        return NO;
    if (!cell.fPlayButtonsView)
        return YES;
    NSString* hash = torrent.hashString;
    if (![flowViewTorrentHash((FlowLayoutView*)cell.fPlayButtonsView) isEqualToString:hash])
        return YES;
    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    NSUInteger buttonCount = [flowView contentSubviews].count;
    if (torrent.playableFiles.count > 0 && buttonCount == 0)
        return YES;
    return NO;
}

- (CGFloat)playButtonsAvailableWidthForCell:(TorrentCell*)cell
{
    CGFloat tableWidth = NSWidth(self.bounds);
    CGFloat leadingX = NSMinX(cell.fTorrentStatusField.frame);
    CGFloat availableWidth = tableWidth - leadingX - kFlowPlayButtonRightMargin - self.intercellSpacing.width;
    return MAX((CGFloat)200.0, availableWidth);
}

- (void)recycleFlowViewForCellReuse:(TorrentCell*)cell
{
    if (!cell.fPlayButtonsView)
        return;
    [self recycleSubviewsFromFlowView:(FlowLayoutView*)cell.fPlayButtonsView];
    setFlowViewTorrentHash((FlowLayoutView*)cell.fPlayButtonsView, @"");
    cell.fPlayButtonsSourceFiles = nil;
}

- (void)recycleSubviewsFromFlowView:(FlowLayoutView*)flowView
{
    if (!flowView)
        return;
    for (NSView* view in [flowView contentSubviews])
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

/// Applies metadata-only UI for play buttons. No filesystem/path probing here.
- (void)applyPathDerivedUIToPlayButton:(PlayButton*)playButton forEntry:(NSDictionary*)entry torrent:(Torrent*)torrent
{
    NSString* type = entry[@"type"] ?: @"file";
    NSString* path = entry[@"path"];
    NSString* folder = entry[@"folder"] ?: @"";
    if (path.length > 0)
        playButton.identifier = path;
    NSString* openLabel = [torrent openCountLabelForPlayableItem:entry];
    NSString* tooltipPath = [torrent tooltipPathForItemPath:path type:type folder:folder];
    NSString* tooltip = tooltipPath.length > 0 ?
        tooltipPath :
        (playButton.title.length > 0 ? playButton.title : NSLocalizedString(@"Play", "Play button tooltip fallback"));
    playButton.toolTip = openLabel.length > 0 ? [NSString stringWithFormat:@"%@\n%@", tooltip, openLabel] : tooltip;
    objc_setAssociatedObject(playButton, &kPlayButtonTypeKey, type, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(playButton, &kPlayButtonFolderKey, folder.length > 0 ? folder : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary* represented = @{ @"torrent" : torrent, @"item" : entry };
    objc_setAssociatedObject(playButton, &kPlayButtonRepresentedKey, represented, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSImage* icon = [self iconForPlayableFileItem:entry torrent:torrent];
    playButton.image = icon;
    playButton.imagePosition = icon ? NSImageLeft : NSNoImage;
}

- (NSString*)pathUiTokenForEntry:(NSDictionary*)entry
{
    NSString* type = entry[@"type"] ?: @"";
    NSString* path = entry[@"path"] ?: @"";
    NSString* folder = entry[@"folder"] ?: @"";
    NSString* category = entry[@"category"] ?: @"";
    return [NSString stringWithFormat:@"%@|%@|%@|%@", type, path, folder, category];
}

- (PlayButton*)setupPlayButtonWithItem:(NSDictionary*)item torrent:(Torrent*)torrent
{
    PlayButton* playButton = [self dequeuePlayButton];
    NSString* type = item[@"type"] ?: @"file";
    CGFloat progress = [item[@"progress"] doubleValue];
    playButton.title = [self menuTitleForPlayableItem:item torrent:torrent includeProgress:YES];
    playButton.tag = [item[@"index"] integerValue];
    [self applyPathDerivedUIToPlayButton:playButton forEntry:item torrent:torrent];
    objc_setAssociatedObject(playButton, &kPlayButtonPathUiTokenKey, [self pathUiTokenForEntry:item], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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

/// Configures play buttons for a cell. Synchronous and simple.
- (void)configurePlayButtonsForCell:(TorrentCell*)cell torrent:(Torrent*)torrent
{
    if (self.fSmallView || ![self showContentButtonsPref])
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
        [self clearFlowViewFromCell:cell];

    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    if (!flowView)
        flowView = [self newFlowViewAddedToCell:cell];

    [flowView removeAllArrangedSubviews];
    setFlowViewTorrentHash(flowView, currentHash);
    cell.fPlayButtonsSourceFiles = playableFiles;

    NSArray<NSDictionary*>* state = [PlayButtonStateBuilder stateForTorrent:torrent];
    if (!state || state.count == 0)
    {
        [self hideFlowViewAndResetRowHeightForCell:cell torrent:torrent];
        return;
    }
    NSArray<NSDictionary*>* layout = [PlayButtonStateBuilder layoutForTorrent:torrent state:state];
    if (!layout || layout.count == 0)
    {
        [self hideFlowViewAndResetRowHeightForCell:cell torrent:torrent];
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSDictionary* entry in layout)
        [self addPlayButtonLayoutEntry:entry toFlowView:flowView torrent:torrent];
    [flowView finishBatchUpdates];
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:YES];
    flowView.hidden = NO;
    [cell setBackgroundStyle:cell.backgroundStyle];
    [CATransaction commit];
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
    if (self.fSmallView || ![self showContentButtonsPref])
        return;
    if (cell.fPlayButtonsView)
    {
        FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
        NSString* flowHash = flowViewTorrentHash(flowView);
        CGFloat const availableWidth = [self playButtonsAvailableWidthForCell:cell];

        if ([flowHash isEqualToString:torrent.hashString] && [flowView hasValidLayoutForWidth:availableWidth] &&
            torrent.cachedPlayButtonProgressGeneration == torrent.statsGeneration)
        {
            return;
        }
        // Visibility changes invalidate the layout; rebuild buttons to add/remove visible items
        if (torrent.cachedPlayButtonLayout == nil)
        {
            [self configurePlayButtonsForCell:cell torrent:torrent];
            return;
        }
        [self updatePlayButtonProgressForCell:cell torrent:torrent];
    }
    else if (torrent.playableFiles.count > 0)
        [self configurePlayButtonsForCell:cell torrent:torrent];
}

@end
