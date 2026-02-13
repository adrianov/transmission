// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "SmallTorrentCell.h"
#import "ProgressBarView.h"
#import "ProgressGradients.h"
#import "TorrentTableView.h"
#import "Torrent.h"

static NSString* const kTrackingAreaRow = @"row";
static NSString* const kTrackingAreaIcon = @"icon";

@interface SmallTorrentCell ()
@property(nonatomic) NSTrackingArea* fRowTrackingArea;
@property(nonatomic) NSTrackingArea* fIconTrackingArea;
@end

@implementation SmallTorrentCell

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];

    NSTrackingArea* area = event.trackingArea;
    NSDictionary* info = area.userInfo;

    if ([kTrackingAreaIcon isEqualToString:info[@"type"]])
    {
        self.fIconHover = YES;
        if (self.fTorrentTableView)
        {
            NSInteger row = [self.fTorrentTableView rowForView:self];
            [self.fTorrentTableView refreshTorrentRowInPlace:row];
        }
    }
    else if ([kTrackingAreaRow isEqualToString:info[@"type"]])
    {
        if (self.fTorrentTableView)
            [self.fTorrentTableView hoverEventBeganForView:self];
    }
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];

    NSTrackingArea* area = event.trackingArea;
    NSDictionary* info = area.userInfo;

    if ([kTrackingAreaIcon isEqualToString:info[@"type"]])
    {
        self.fIconHover = NO;
        if (self.fTorrentTableView)
        {
            NSInteger row = [self.fTorrentTableView rowForView:self];
            [self.fTorrentTableView refreshTorrentRowInPlace:row];
        }
    }
    else if ([kTrackingAreaRow isEqualToString:info[@"type"]])
    {
        self.fIconHover = NO;
        if (self.fTorrentTableView)
            [self.fTorrentTableView hoverEventEndedForView:self];
    }
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];

    if (self.fRowTrackingArea != nil)
    {
        [self removeTrackingArea:self.fRowTrackingArea];
        self.fRowTrackingArea = nil;
    }
    if (self.fIconTrackingArea != nil)
    {
        [self removeTrackingArea:self.fIconTrackingArea];
        self.fIconTrackingArea = nil;
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

    if (!NSIsEmptyRect(rowRect))
    {
        NSDictionary* rowInfo = @{ @"type" : kTrackingAreaRow };
        self.fRowTrackingArea = [[NSTrackingArea alloc] initWithRect:rowRect
                                                              options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                                                owner:self
                                                             userInfo:rowInfo];
        [self addTrackingArea:self.fRowTrackingArea];
    }

    NSRect iconRect = self.fIconView ? self.fIconView.frame : NSZeroRect;
    if (!NSIsEmptyRect(iconRect))
    {
        NSDictionary* iconInfo = @{ @"type" : kTrackingAreaIcon };
        self.fIconTrackingArea = [[NSTrackingArea alloc] initWithRect:iconRect
                                                               options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                                                 owner:self
                                                              userInfo:iconInfo];
        [self addTrackingArea:self.fIconTrackingArea];
    }

    if (self.window != nil)
    {
        NSPoint mouseLocation = [self.window mouseLocationOutsideOfEventStream];
        mouseLocation = [self convertPoint:mouseLocation fromView:nil];
        self.fIconHover = !NSIsEmptyRect(iconRect) && NSPointInRect(mouseLocation, iconRect);
    }
}

@end
