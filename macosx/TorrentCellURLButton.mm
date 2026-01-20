// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellURLButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@interface TorrentCellURLButton ()
@property(nonatomic) NSTrackingArea* fTrackingArea;
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

- (void)updateImage
{
    NSImage* urlImage = [NSImage imageNamed:self.urlImageString];
    self.image = urlImage;
    self.needsDisplay = YES;
}

- (void)updateTrackingAreas
{
    if (self.fTrackingArea != nil)
    {
        [self removeTrackingArea:self.fTrackingArea];
    }

    NSTrackingAreaOptions opts = (NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways);
    self.fTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.fTrackingArea];
}

@end
