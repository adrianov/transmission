// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "NSApplicationAdditions.h"
#import "PlayButton.h"

// Regression: NSButtonCell can ignore attributed title color. We draw the title ourselves so
// selected rows use white and watched/unwatched use theme-consistent colors in both light and dark.

/// Bezel fill uses PlayButton.fillColorUnwatched:hovered:. Title uses PlayButton.titleColorUnwatched: (selected row = white).
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

- (NSRect)drawTitle:(NSAttributedString*)title withFrame:(NSRect)frame inView:(NSView*)controlView
{
    PlayButton* button = [controlView isKindOfClass:[PlayButton class]] ? (PlayButton*)controlView : nil;
    NSColor* color;
    if (self.backgroundStyle == NSBackgroundStyleEmphasized)
        color = NSColor.whiteColor;
    else
        color = button ? [PlayButton titleColorUnwatched:button.iinaUnwatched] : NSColor.controlTextColor;
    NSString* str = title.string ?: @"";
    if (str.length > 0)
    {
        NSMutableAttributedString* attr = [[NSMutableAttributedString alloc] initWithString:str];
        [attr addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, str.length)];
        [attr addAttribute:NSFontAttributeName value:self.font ?: [NSFont systemFontOfSize:11] range:NSMakeRange(0, str.length)];
        [attr drawInRect:frame];
    }
    return frame;
}

@end

@implementation PlayButton

+ (NSColor*)fillColorUnwatched:(BOOL)unwatched hovered:(BOOL)hovered
{
    if (unwatched)
        return hovered ? [NSColor colorWithCalibratedRed:0.2 green:0.54 blue:0.2 alpha:0.65] :
                         [NSColor colorWithCalibratedRed:0.16 green:0.44 blue:0.16 alpha:0.6];
    // Watched (played): theme-adaptive. Dark = dark gray; light = very light gray so buttons read clearly on white.
    if (NSApp.darkMode)
        return hovered ? [NSColor colorWithCalibratedWhite:0.15 alpha:0.6] :
                         [NSColor colorWithCalibratedWhite:0.1 alpha:0.5];
    return hovered ? [NSColor colorWithCalibratedWhite:0.88 alpha:0.9] :
                     [NSColor colorWithCalibratedWhite:0.82 alpha:0.85];
}

+ (NSColor*)titleColorUnwatched:(BOOL)unwatched
{
    if (unwatched)
        return [NSColor colorWithCalibratedWhite:1.0 alpha:0.95];
    // Watched (gray button): explicit colors so text is consistent in light and dark themes.
    if (NSApp.darkMode)
        return [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
    return [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
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
