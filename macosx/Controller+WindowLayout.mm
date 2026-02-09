// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Main window layout: status/filter bars, AutoSize, fullscreen, height constraints.

#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "Badger.h"
#import "FilterBarController.h"
#import "StatusBarController.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (WindowLayout)

- (void)updateMainWindow
{
    if (self.fStatusBar == nil)
    {
        self.fStatusBar = [[StatusBarController alloc] initWithLib:self.fLib];
        self.fStatusBar.layoutAttribute = NSLayoutAttributeBottom;
        self.fStatusBar.automaticallyAdjustsSize = NO;

        [self.fWindow addTitlebarAccessoryViewController:self.fStatusBar];
    }

    if ([self.fDefaults boolForKey:@"StatusBar"])
        self.fStatusBar.hidden = NO;
    else
        self.fStatusBar.hidden = YES;

    if (self.fFilterBar == nil)
    {
        self.fFilterBar = [[FilterBarController alloc] init];
        self.fFilterBar.layoutAttribute = NSLayoutAttributeBottom;
        self.fFilterBar.automaticallyAdjustsSize = NO;

        [self.fWindow addTitlebarAccessoryViewController:self.fFilterBar];
    }

    if ([self.fDefaults boolForKey:@"FilterBar"])
    {
        self.fFilterBar.hidden = NO;
        [self focusFilterField];
    }
    else
        self.fFilterBar.hidden = YES;

    [self fullUpdateUI];
    [self updateForAutoSize];
}

- (void)setWindowSizeToFit
{
    if (self.isFullScreen)
        return;

    if (![self.fDefaults boolForKey:@"AutoSize"])
    {
        NSScrollView* scrollView = self.fTableView.enclosingScrollView;
        [self removeHeightConstraints];

        CGFloat height = self.minScrollViewHeightAllowed;
        if (self.fMinHeightConstraint == nil)
            self.fMinHeightConstraint = [scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:height];
        else
            self.fMinHeightConstraint.constant = height;
        self.fMinHeightConstraint.active = YES;
        return;
    }

    NSInteger rowCount = self.fTableView.numberOfRows;
    CGFloat tableContentHeight = 0;
    if (rowCount > 0)
    {
        NSRect lastRowRect = [self.fTableView rectOfRow:rowCount - 1];
        tableContentHeight = NSMaxY(lastRowRect);
    }
    tableContentHeight = MAX(tableContentHeight, self.minScrollViewHeightAllowed);

    NSScrollView* scrollView = self.fTableView.enclosingScrollView;
    CGFloat currentContentHeight = self.fWindow.contentView.frame.size.height;
    CGFloat currentScrollViewHeight = scrollView.frame.size.height;
    CGFloat otherComponentsHeight = currentContentHeight - currentScrollViewHeight;
    CGFloat contentHeight = tableContentHeight + otherComponentsHeight;

    NSRect contentRect = NSMakeRect(0, 0, self.fWindow.contentView.frame.size.width, contentHeight);
    NSRect newFrame = [self.fWindow frameRectForContentRect:contentRect];

    NSRect oldFrame = self.fWindow.frame;
    newFrame.origin.x = oldFrame.origin.x;
    newFrame.origin.y = NSMaxY(oldFrame) - newFrame.size.height;

    NSScreen* screen = self.fWindow.screen;
    if (screen)
    {
        NSRect visibleFrame = screen.visibleFrame;
        if (NSMinY(newFrame) < NSMinY(visibleFrame))
            newFrame.origin.y = NSMinY(visibleFrame);
        if (NSMaxY(newFrame) > NSMaxY(visibleFrame))
        {
            newFrame.origin.y = NSMaxY(visibleFrame) - newFrame.size.height;
            if (NSMinY(newFrame) < NSMinY(visibleFrame))
            {
                newFrame.origin.y = NSMinY(visibleFrame);
                newFrame.size.height = visibleFrame.size.height;
            }
        }
    }

    [self.fWindow setFrame:newFrame display:YES animate:NO];
}

- (void)updateForAutoSize
{
    if (!self.isFullScreen)
        [self setWindowSizeToFit];
    else
        [self removeHeightConstraints];
}

- (void)updateWindowAfterToolbarChange
{
    if (!self.isFullScreen)
    {
        if (!self.fWindow.toolbar.isVisible)
            [self removeHeightConstraints];
        [self hideToolBarBezels:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateForAutoSize];
            [self hideToolBarBezels:NO];
        });
    }
}

- (void)hideToolBarBezels:(BOOL)hide
{
    for (NSToolbarItem* item in self.fWindow.toolbar.items)
        item.view.hidden = hide;
}

- (void)removeHeightConstraints
{
    if (self.fFixedHeightConstraint != nil)
        self.fFixedHeightConstraint.active = NO;
    if (self.fMinHeightConstraint != nil)
        self.fMinHeightConstraint.active = NO;
}

- (CGFloat)minScrollViewHeightAllowed
{
    return self.fTableView.rowHeight + self.fTableView.intercellSpacing.height;
}

- (CGFloat)toolbarHeight
{
    return self.fWindow.frame.size.height - [self.fWindow contentRectForFrameRect:self.fWindow.frame].size.height;
}

- (CGFloat)mainWindowComponentHeight
{
    CGFloat height = kBottomBarHeight;
    if (self.fStatusBar != nil && !self.fStatusBar.isHidden)
        height += kStatusBarHeight;
    if (self.fFilterBar != nil && !self.fFilterBar.isHidden)
        height += kFilterBarHeight;
    return height;
}

- (CGFloat)scrollViewHeight
{
    return NSHeight(self.fTableView.enclosingScrollView.frame);
}

- (BOOL)isFullScreen
{
    return (self.fWindow.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen;
}

- (void)windowWillEnterFullScreen:(NSNotification*)notification
{
    [self removeHeightConstraints];
}

- (void)windowDidExitFullScreen:(NSNotification*)notification
{
    [self updateForAutoSize];
}

- (void)updateForExpandCollapse
{
    [self setWindowSizeToFit];
    [self setBottomCountText:YES];
}

- (void)showMainWindow:(id)sender
{
    [self.fWindow makeKeyAndOrderFront:nil];
}

- (void)windowDidBecomeMain:(NSNotification*)notification
{
    [self.fBadger clearCompleted];
    [self updateUI];
}

- (void)applicationWillUnhide:(NSNotification*)notification
{
    [self updateUI];
}

@end
#pragma clang diagnostic pop
