// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellURLButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@interface TorrentCellURLButton ()
@property(nonatomic, copy) NSString* urlImageString;
@property(nonatomic) IBOutlet TorrentCell* torrentCell;
@property(nonatomic, readonly) TorrentTableView* torrentTableView;
@end

@implementation TorrentCellURLButton

- (TorrentTableView*)torrentTableView
{
    return self.torrentCell.fTorrentTableView;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    self.urlImageString = @"URLOff";
    [self updateImage];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    self.urlImageString = @"URLHover";
    [self updateImage];

    [self.torrentTableView hoverEventBeganForView:self];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    self.urlImageString = @"URLOff";
    [self updateImage];

    [self.torrentTableView hoverEventEndedForView:self];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self.torrentTableView];
    [super mouseDown:event];
    self.urlImageString = @"URLOn";
    [self updateImage];
}

- (void)resetImage
{
    self.urlImageString = @"URLOff";
    [self updateImage];
}

- (void)updateImage
{
    NSImage* urlImage = [NSImage imageNamed:self.urlImageString];
    self.image = urlImage;
    self.needsDisplay = YES;
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
