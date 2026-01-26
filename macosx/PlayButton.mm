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
        self.canDrawConcurrently = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

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
    self.onHover = nil;
    self.accessibilityHelp = nil;
    self.accessibilityLabel = nil;
    self.toolTip = nil;
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

- (void)updateBackground
{
    NSColor* bgColor = self.isHovered ? [NSColor colorWithWhite:0.0 alpha:0.15] : [NSColor colorWithWhite:0.0 alpha:0.07];
    self.layer.backgroundColor = bgColor.CGColor;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    [self updateBackground];
}

- (void)drawRect:(NSRect)dirtyRect
{
    // Layer handles background drawing via updateLayer
    [super drawRect:dirtyRect];
}

@end
