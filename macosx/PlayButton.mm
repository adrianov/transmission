// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "PlayButton.h"

@implementation PlayButton

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        [self setupTrackingArea];
        self.cell.lineBreakMode = NSLineBreakByTruncatingTail;
        self.cell.truncatesLastVisibleLine = YES;
    }
    return self;
}

- (void)setupTrackingArea
{
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                                options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                                  owner:self
                                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
}

- (void)mouseEntered:(NSEvent*)event
{
    self.isHovered = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event
{
    self.isHovered = NO;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Draw background - lighter normally, darker on hover
    NSColor* bgColor = self.isHovered ? [NSColor colorWithWhite:0.0 alpha:0.15] : [NSColor colorWithWhite:0.0 alpha:0.07];
    [bgColor setFill];
    NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4];
    [path fill];

    [super drawRect:dirtyRect];
}

@end
