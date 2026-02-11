// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellRevealButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@interface TorrentCellRevealButton ()
@property(nonatomic, copy) NSString* revealImageString;
@property(nonatomic) IBOutlet TorrentCell* torrentCell;
@property(nonatomic, readonly) TorrentTableView* torrentTableView;
@end

@implementation TorrentCellRevealButton

- (TorrentTableView*)torrentTableView
{
    return self.torrentCell.fTorrentTableView;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

    self.revealImageString = @"RevealOff";
    [self updateImage];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    self.revealImageString = @"RevealHover";
    [self updateImage];

    [self.torrentTableView hoverEventBeganForView:self];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    self.revealImageString = @"RevealOff";
    [self updateImage];

    [self.torrentTableView hoverEventEndedForView:self];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self.torrentTableView];
    [super mouseDown:event];
    self.revealImageString = @"RevealOn";
    [self updateImage];
}

- (void)resetImage
{
    self.revealImageString = @"RevealOff";
    [self updateImage];
}

- (void)updateImage
{
    NSImage* revealImage = [NSImage imageNamed:self.revealImageString];
    self.image = revealImage;
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
