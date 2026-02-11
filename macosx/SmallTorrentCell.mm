// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "SmallTorrentCell.h"
#import "ProgressBarView.h"
#import "ProgressGradients.h"
#import "TorrentTableView.h"
#import "Torrent.h"

@interface SmallTorrentCell ()
@property(nonatomic) NSTrackingArea* fTrackingArea;
@end

@implementation SmallTorrentCell

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    NSPoint p = [self.window mouseLocationOutsideOfEventStream];
    p = [self convertPoint:p fromView:nil];
    NSRect iconRect = self.fIconView ? self.fIconView.frame : NSZeroRect;
    self.fIconHover = !NSIsEmptyRect(iconRect) && NSPointInRect(p, iconRect);
    [self.fTorrentTableView hoverEventBeganForView:self];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    self.fIconHover = NO;
    [self.fTorrentTableView hoverEventEndedForView:self];
}

- (void)mouseMoved:(NSEvent*)event
{
    NSPoint p = [self.window mouseLocationOutsideOfEventStream];
    p = [self convertPoint:p fromView:nil];
    NSRect iconRect = self.fIconView ? self.fIconView.frame : NSZeroRect;
    BOOL inIcon = !NSIsEmptyRect(iconRect) && NSPointInRect(p, iconRect);
    if (inIcon != self.fIconHover)
    {
        self.fIconHover = inIcon;
        NSInteger row = [self.fTorrentTableView rowForView:self];
        [self.fTorrentTableView refreshTorrentRowInPlace:row];
    }
}

- (void)mouseUp:(NSEvent*)event
{
    [super mouseUp:event];
    [self updateTrackingAreas];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];

    if (self.fTrackingArea != nil)
    {
        [self removeTrackingArea:self.fTrackingArea];
    }

    NSRect rowRect = self.bounds;
    if (self.fTorrentTableView)
    {
        NSInteger row = [self.fTorrentTableView rowForView:self];
        if (row >= 0)
        {
            NSRect tableRowRect = [self.fTorrentTableView rectOfRow:row];
            rowRect = [self convertRect:tableRowRect fromView:self.fTorrentTableView];
        }
    }
    NSTrackingAreaOptions opts = (NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow);
    self.fTrackingArea = [[NSTrackingArea alloc] initWithRect:rowRect options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.fTrackingArea];

    NSPoint mouseLocation = [self.window mouseLocationOutsideOfEventStream];
    mouseLocation = [self convertPoint:mouseLocation fromView:nil];
    if (NSPointInRect(mouseLocation, rowRect))
        [self mouseEntered:[[NSEvent alloc] init]];
    else
        [self mouseExited:[[NSEvent alloc] init]];
}

@end
