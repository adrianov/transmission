// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellActionButton.h"
#import "TorrentTableView.h"
#import "Torrent.h"
#import "TorrentCell.h"

@interface TorrentCellActionButton ()
@property(nonatomic) IBOutlet TorrentCell* torrentCell;
@property(nonatomic, readonly) TorrentTableView* torrentTableView;
@end

@implementation TorrentCellActionButton

- (TorrentTableView*)torrentTableView
{
    return self.torrentCell.fTorrentTableView;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    [self.cell setHighlightsBy:NSNoCellMask];
    self.image = [NSImage imageNamed:@"ActionHover"];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    [self.torrentTableView hoverEventBeganForView:self];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    [self.torrentTableView hoverEventEndedForView:self];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self.torrentTableView];
    [super mouseDown:event];

    BOOL minimal = [NSUserDefaults.standardUserDefaults boolForKey:@"SmallView"];
    if (!minimal)
        [self.torrentTableView hoverEventEndedForView:self];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea* area in self.trackingAreas)
    {
        if (area.owner == self && (area.options & NSTrackingInVisibleRect))
        {
            [self removeTrackingArea:area];
            break;
        }
    }
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
}

@end
