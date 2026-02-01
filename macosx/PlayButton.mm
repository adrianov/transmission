// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "PlayButton.h"

/// Bezel fill uses PlayButton.fillColorUnwatched:hovered:. No system bezel.
@interface PlayButtonCell : NSButtonCell
@end

@implementation PlayButtonCell

- (void)drawBezelWithFrame:(NSRect)frame inView:(NSView*)controlView
{
    if (NSIsEmptyRect(frame))
        return;
    PlayButton* button = [controlView isKindOfClass:[PlayButton class]] ? (PlayButton*)controlView : nil;
    BOOL hovered = button ? button.isHovered : NO;
    BOOL unwatched = button ? button.iinaUnwatched : NO;
    NSColor* fill = [PlayButton fillColorUnwatched:unwatched hovered:hovered];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:4.0 yRadius:4.0] fill];
}

@end

@implementation PlayButton

+ (NSColor*)fillColorUnwatched:(BOOL)unwatched hovered:(BOOL)hovered
{
    if (unwatched)
        return hovered ? [NSColor colorWithCalibratedRed:0.28 green:0.72 blue:0.28 alpha:0.65] :
                         [NSColor colorWithCalibratedRed:0.22 green:0.62 blue:0.22 alpha:0.6];
    return hovered ? [NSColor colorWithCalibratedWhite:0.15 alpha:0.6] :
                     [NSColor colorWithCalibratedWhite:0.1 alpha:0.5];
}

+ (Class)cellClass
{
    return [PlayButtonCell class];
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        // No layer so the cell's drawBezelWithFrame is used (reliable in table/scroll views).
        self.bordered = YES;
        self.bezelStyle = NSBezelStyleRounded;
        self.showsBorderOnlyWhileMouseInside = NO;
        self.font = [NSFont systemFontOfSize:11];
        self.controlSize = NSControlSizeSmall;
        self.imagePosition = NSImageLeft;
        self.imageScaling = NSImageScaleProportionallyDown;

        [self setupTrackingArea];
        self.cell.lineBreakMode = NSLineBreakByTruncatingTail;
        self.cell.truncatesLastVisibleLine = YES;
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
    [self setNeedsDisplay:YES];
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
    [self setNeedsDisplay:YES];
    if (self.onHover)
        self.onHover(self);
}

- (void)mouseExited:(NSEvent*)event
{
    self.isHovered = NO;
    [self setNeedsDisplay:YES];
}

- (void)setIinaUnwatched:(BOOL)iinaUnwatched
{
    if (_iinaUnwatched != iinaUnwatched)
    {
        _iinaUnwatched = iinaUnwatched;
        [self setNeedsDisplay:YES];
    }
}

@end
