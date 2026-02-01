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
        self.wantsLayer = YES;
        self.layer.cornerRadius = 4.0;
        self.layer.masksToBounds = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

        // Default styling for all play buttons
        self.bezelStyle = NSBezelStyleRecessed;
        self.showsBorderOnlyWhileMouseInside = YES;
        self.font = [NSFont systemFontOfSize:11];
        self.controlSize = NSControlSizeSmall;
        self.imagePosition = NSImageLeft;
        self.imageScaling = NSImageScaleProportionallyDown;

        [self setupTrackingArea];
        self.cell.lineBreakMode = NSLineBreakByTruncatingTail;
        self.cell.truncatesLastVisibleLine = YES;

        [self updateBackground];
    }
    return self;
}

- (void)prepareForReuse
{
    self.title = @"";
    self.image = nil;
    self.tag = NSNotFound;
    self.identifier = nil;
    self.hidden = NO;
    self.isHovered = NO;
    self.iinaUnwatched = NO;
    self.onHover = nil;
    self.accessibilityHelp = nil;
    self.accessibilityLabel = nil;
    self.toolTip = nil;
    self.state = NSControlStateValueOff;
    self.highlighted = NO;
    [self updateBackground];
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
    [self updateBackground];

    if (self.onHover)
    {
        self.onHover(self);
    }
}

- (void)mouseExited:(NSEvent*)event
{
    self.isHovered = NO;
    [self updateBackground];
}

- (void)setIinaUnwatched:(BOOL)iinaUnwatched
{
    if (_iinaUnwatched != iinaUnwatched)
    {
        _iinaUnwatched = iinaUnwatched;
        [self updateBackground];
    }
}

- (void)updateBackground
{
    NSColor* bgColor;
    if (self.iinaUnwatched)
        bgColor = self.isHovered ? [NSColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.35] :
                                   [NSColor colorWithRed:0.2 green:0.55 blue:0.2 alpha:0.25];
    else
        bgColor = self.isHovered ? [NSColor colorWithWhite:0.0 alpha:0.12] : [NSColor colorWithWhite:0.0 alpha:0.05];
    self.layer.backgroundColor = bgColor.CGColor;
}

@end
