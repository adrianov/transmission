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
#include <cmath>
#import <objc/runtime.h>

static char const kFlowViewTorrentHashKey = '\0';
extern char const kPlayButtonTypeKey;
extern char const kPlayButtonFolderKey;
extern char const kPlayButtonRepresentedKey;
static CGFloat const kFlowPlayButtonRightMargin = 55.0;
static CGFloat const kFlowPlayButtonRowHeight = 18.0;
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

    NSDictionary* snapshotDict = [self buildFlowSnapshotForTorrent:torrent];
    if (!snapshotDict)
        return;
    NSArray* snapshot = snapshotDict[@"snapshot"];
    NSArray* playableFilesForApply = snapshotDict[@"playableFiles"];
    NSDictionary* result = [PlayButtonStateBuilder stateAndLayoutFromSnapshot:snapshot];
    NSMutableArray* state = result[@"state"];
    NSArray* layout = result[@"layout"];
    [PlayButtonStateBuilder enrichStateWithIinaUnwatched:state forTorrent:torrent];

    torrent.cachedPlayButtonSource = playableFilesForApply;
    torrent.cachedPlayButtonState = state;
    torrent.cachedPlayButtonLayout = layout;
    torrent.cachedPlayButtonProgressGeneration = torrent.statsGeneration;

    if (layout.count == 0)
    {
        [self hideFlowViewAndResetRowHeightForCell:cell torrent:torrent];
        return;
    }
    for (NSDictionary* entry in layout)
        [self addPlayButtonLayoutEntry:entry toFlowView:flowView torrent:torrent];
    [flowView finishBatchUpdates];
    [self updatePlayButtonProgressForCell:cell torrent:torrent forceLayout:YES];
    flowView.hidden = NO;
    [cell setBackgroundStyle:cell.backgroundStyle];
    [flowView setNeedsDisplay:YES];
    [cell setNeedsDisplay:YES];
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
        [self updatePlayButtonProgressForCell:cell torrent:torrent];
    else if (torrent.playableFiles.count > 0)
        [self configurePlayButtonsForCell:cell torrent:torrent];
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
    for (NSView* v in [flowView contentSubviews])
    {
        if ([v isKindOfClass:[PlayButton class]])
            playButtonCount++;
    }
    if (anyVisible && playButtonCount == 0)
    {
        [self configurePlayButtonsForCell:cell torrent:torrent];
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

    for (NSView* view in [flowView contentSubviews])
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
                    BOOL titleChanged = ![button.title isEqualToString:title];
                    if (titleChanged)
                    {
                        button.title = title;
                        [button invalidateIntrinsicContentSize];
                        [flowView invalidateSizeForView:button];
                        layoutNeeded = YES;
                    }
                    NSNumber* iinaUnwatchedNum = entry[@"iinaUnwatched"];
                    BOOL iinaUnwatched = iinaUnwatchedNum ? iinaUnwatchedNum.boolValue : NO;
                    BOOL watchedChanged = (button.iinaUnwatched != iinaUnwatched);
                    if (watchedChanged)
                    {
                        button.iinaUnwatched = iinaUnwatched;
                        layoutNeeded = YES;
                    }
                    // Only rebuild attributedTitle when title or color actually changed,
                    // avoiding NSMutableAttributedString allocation on every scroll update.
                    if (titleChanged || watchedChanged)
                    {
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
