// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Content button progress/visibility updates for the flow view.

#import "FlowLayoutView.h"
#import "PlayButton.h"
#import "PlayButtonStateBuilder.h"
#import "Torrent.h"
#import "TorrentCell.h"
#import "TorrentTableView.h"
#import "TorrentTableViewPrivate.h"
#include <cmath>
#import <objc/runtime.h>

extern char const kPlayButtonRepresentedKey;
static CGFloat const kFlowPlayButtonRowHeight = 18.0;
static CGFloat const kFlowPlayButtonVerticalPadding = 4.0;

static BOOL setHeaderHidden(NSTextField* header, NSView* lineBreak, BOOL hidden)
{
    if (!header || header.hidden == hidden)
        return NO;
    header.hidden = hidden;
    if (lineBreak)
        lineBreak.hidden = hidden;
    return YES;
}

static BOOL stateHasVisibleEntry(NSArray<NSDictionary*>* state)
{
    for (NSDictionary* e in state)
    {
        if ([e[@"visible"] boolValue])
            return YES;
    }
    return NO;
}

static NSUInteger playButtonCountInViews(NSArray<NSView*>* views)
{
    NSUInteger count = 0;
    Class const playButtonClass = [PlayButton class];
    for (NSView* v in views)
    {
        if ([v isKindOfClass:playButtonClass])
            count++;
    }
    return count;
}

@implementation TorrentTableView (FlowProgress)

- (NSDictionary*)playButtonStateEntryForButton:(PlayButton*)button
                                       torrent:(Torrent*)torrent
                                       byIndex:(NSDictionary*)byIndex
                                      byFolder:(NSDictionary*)byFolder
{
    NSDictionary* represented = objc_getAssociatedObject(button, &kPlayButtonRepresentedKey);
    NSDictionary* item = [represented isKindOfClass:[NSDictionary class]] ? represented[@"item"] : nil;
    if (item)
    {
        NSNumber* idx = item[@"index"];
        if (idx)
            return byIndex[idx];
        NSString* folder = item[@"folder"];
        if (folder.length > 0)
            return byFolder[folder];
    }
    if (button.tag != NSNotFound)
        return byIndex[@(button.tag)];
    NSString* folder = [self folderForPlayButton:button torrent:torrent];
    return folder.length > 0 ? byFolder[folder] : nil;
}

- (void)applyPlayButtonTitle:(NSString*)title unwatched:(BOOL)unwatched toButton:(PlayButton*)button
{
    NSColor* titleColor = [PlayButton titleColorUnwatched:unwatched];
    NSDictionary* attrs = @{ NSForegroundColorAttributeName : titleColor, NSFontAttributeName : [PlayButton titleFont] };
    button.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
    [button setNeedsDisplay:YES];
}

- (BOOL)updatePlayButton:(PlayButton*)button
               withEntry:(NSDictionary*)entry
                 torrent:(Torrent*)torrent
                flowView:(FlowLayoutView*)flowView
             forceLayout:(BOOL)forceLayout
{
    NSNumber* visibleNum = entry[@"visible"];
    NSString* title = entry[@"title"];
    if (!visibleNum || !title)
        return NO;

    BOOL layoutNeeded = NO;
    BOOL const shouldBeHidden = !visibleNum.boolValue;
    BOOL const becameVisible = button.hidden && !shouldBeHidden;
    if (button.hidden != shouldBeHidden)
    {
        button.hidden = shouldBeHidden;
        layoutNeeded = YES;
    }

    BOOL titleChanged = ![button.title isEqualToString:title];
    if (titleChanged)
    {
        button.title = title;
        [button invalidateIntrinsicContentSize];
        [flowView invalidateSizeForView:button];
        layoutNeeded = YES;
    }

    NSNumber* iinaUnwatchedNum = entry[@"iinaUnwatched"];
    BOOL iinaUnwatched = iinaUnwatchedNum.boolValue;
    BOOL watchedChanged = (button.iinaUnwatched != iinaUnwatched);
    if (watchedChanged)
    {
        button.iinaUnwatched = iinaUnwatched;
        layoutNeeded = YES;
    }
    if (titleChanged || watchedChanged)
        [self applyPlayButtonTitle:title unwatched:button.iinaUnwatched toButton:button];

    // Path-derived UI is expensive (filesystem/path checks); refresh only when needed.
    // Entry dictionaries are stable objects mutated in place across ticks, so pointer
    // identity proves type/path/folder/category are unchanged — no token string build needed.
    NSDictionary* represented = objc_getAssociatedObject(button, &kPlayButtonRepresentedKey);
    NSDictionary* representedItem = [represented isKindOfClass:[NSDictionary class]] ? represented[@"item"] : nil;
    if (forceLayout || becameVisible || representedItem != entry)
    {
        [self applyPathDerivedUIToPlayButton:button forEntry:entry torrent:torrent];
        objc_setAssociatedObject(button, &kPlayButtonRepresentedKey, @{ @"torrent" : torrent, @"item" : entry }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return layoutNeeded;
}

- (void)applyPlayButtonsHeightForCell:(TorrentCell*)cell torrent:(Torrent*)torrent flowView:(FlowLayoutView*)flowView
{
    CGFloat const availableWidth = [self playButtonsAvailableWidthForCell:cell];
    BOOL useSavedHeight = [flowView hasValidLayoutForWidth:availableWidth] && flowView.lastLayoutHeight > 0;
    CGFloat buttonHeight = useSavedHeight ? flowView.lastLayoutHeight : [flowView heightForWidth:availableWidth];
    if (buttonHeight > 0 && buttonHeight < kFlowPlayButtonRowHeight)
        buttonHeight = kFlowPlayButtonRowHeight;
    if (cell.fPlayButtonsHeightConstraint)
        cell.fPlayButtonsHeightConstraint.constant = buttonHeight;
    CGFloat totalHeight = self.rowHeight + (buttonHeight > 0 ? (buttonHeight + kFlowPlayButtonVerticalPadding) : 0);
    CGFloat oldHeight = torrent.content.cachedPlayButtonsHeight;
    torrent.content.cachedPlayButtonsHeight = totalHeight;
    torrent.content.cachedPlayButtonsWidth = availableWidth;
    if (std::fabs(totalHeight - oldHeight) > 1.0)
    {
        NSInteger row = [self rowForItem:torrent];
        [self queueHeightUpdateForRow:row];
        if (buttonHeight > 0)
            [self noteHeightUpdateForRow:row];
    }
}

- (void)clearEmptyPlayButtonsForCell:(TorrentCell*)cell torrent:(Torrent*)torrent flowView:(FlowLayoutView*)flowView
{
    flowView.hidden = YES;
    if (cell.fPlayButtonsHeightConstraint)
        cell.fPlayButtonsHeightConstraint.constant = 0;
    [flowView invalidateIntrinsicContentSize];
    if (torrent.content.cachedPlayButtonsHeight > 0.5)
    {
        torrent.content.cachedPlayButtonsHeight = 0;
        [self queueHeightUpdateForRow:[self rowForItem:torrent]];
    }
}

/// Post-config finish pass: hide season headers whose section has no visible buttons, then size the flow view.
/// Buttons were just built from the same state/layout, so no per-button work happens here.
- (void)finishPlayButtonsConfigurationForCell:(TorrentCell*)cell torrent:(Torrent*)torrent flowView:(FlowLayoutView*)flowView
{
    Class const playButtonClass = [PlayButton class];
    Class const textFieldClass = [NSTextField class];
    NSView* currentLineBreak = nil;
    NSTextField* currentHeader = nil;
    BOOL anyButtonVisibleInSection = NO;

    for (NSView* view in [flowView contentSubviews])
    {
        if ([view isKindOfClass:textFieldClass])
        {
            setHeaderHidden(currentHeader, currentLineBreak, !anyButtonVisibleInSection);
            currentHeader = (NSTextField*)view;
            anyButtonVisibleInSection = NO;
            continue;
        }
        if (![view isKindOfClass:playButtonClass])
        {
            currentLineBreak = view;
            continue;
        }
        if (!view.hidden)
            anyButtonVisibleInSection = YES;
    }
    setHeaderHidden(currentHeader, currentLineBreak, !anyButtonVisibleInSection);

    [self applyPlayButtonsHeightForCell:cell torrent:torrent flowView:flowView];
}

/// Syncs play-button and season-header visibility/titles. Returns YES if layout must be recomputed.
- (BOOL)syncPlayButtonViews:(NSArray<NSView*>*)subviews
                   flowView:(FlowLayoutView*)flowView
                    torrent:(Torrent*)torrent
                forceLayout:(BOOL)forceLayout
{
    NSDictionary* byIndex = torrent.content.cachedPlayButtonStateByIndex;
    NSDictionary* byFolder = torrent.content.cachedPlayButtonStateByFolder;
    BOOL layoutNeeded = forceLayout;
    NSView* currentLineBreak = nil;
    NSTextField* currentHeader = nil;
    BOOL anyButtonVisibleInSection = NO;
    Class const playButtonClass = [PlayButton class];
    Class const textFieldClass = [NSTextField class];

    for (NSView* view in subviews)
    {
        if ([view isKindOfClass:textFieldClass])
        {
            layoutNeeded = setHeaderHidden(currentHeader, currentLineBreak, !anyButtonVisibleInSection) || layoutNeeded;
            currentHeader = (NSTextField*)view;
            anyButtonVisibleInSection = NO;
            continue;
        }
        if (![view isKindOfClass:playButtonClass])
        {
            currentLineBreak = view;
            continue;
        }

        PlayButton* button = (PlayButton*)view;
        NSDictionary* entry = [self playButtonStateEntryForButton:button torrent:torrent byIndex:byIndex byFolder:byFolder];
        if (!entry[@"visible"] || !entry[@"title"])
            continue;
        if ([self updatePlayButton:button withEntry:entry torrent:torrent flowView:flowView forceLayout:forceLayout])
            layoutNeeded = YES;
        if ([entry[@"visible"] boolValue])
            anyButtonVisibleInSection = YES;
    }

    return setHeaderHidden(currentHeader, currentLineBreak, !anyButtonVisibleInSection) || layoutNeeded;
}

/// Syncs buttons with cached state. Returns YES when view work ran (sync/clear/reconfigure), NO when skipped as unchanged.
- (BOOL)updatePlayButtonProgressForCell:(TorrentCell*)cell
                                torrent:(Torrent*)torrent
                             knownState:(NSArray<NSDictionary*>*)knownState
                                changed:(BOOL)stateChanged
{
    FlowLayoutView* flowView = (FlowLayoutView*)cell.fPlayButtonsView;
    if (![flowView isKindOfClass:[FlowLayoutView class]])
        return NO;

    NSArray<NSDictionary*>* state = knownState;
    if (!state)
        state = [PlayButtonStateBuilder stateForTorrent:torrent changedOut:&stateChanged];
    if (state.count == 0)
    {
        BOOL wasVisible = !flowView.hidden || torrent.content.cachedPlayButtonsHeight > 0.5;
        [self clearEmptyPlayButtonsForCell:cell torrent:torrent flowView:flowView];
        return wasVisible;
    }

    NSArray<NSView*>* subviews = [flowView contentSubviews];
    if (stateHasVisibleEntry(state) && playButtonCountInViews(subviews) == 0)
    {
        [self configurePlayButtonsForCell:cell torrent:torrent];
        return YES;
    }

    CGFloat const availableWidth = [self playButtonsAvailableWidthForCell:cell];
    if (!stateChanged && [flowView hasValidLayoutForWidth:availableWidth])
        return NO; // Nothing view-visible changed since the last sync; skip per-button work.

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if ([self syncPlayButtonViews:subviews flowView:flowView torrent:torrent forceLayout:NO])
        [self applyPlayButtonsHeightForCell:cell torrent:torrent flowView:flowView];
    [CATransaction commit];
    return YES;
}

- (void)noteHeightUpdateForRow:(NSInteger)row
{
    [self noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:(NSUInteger)row]];
}

@end
