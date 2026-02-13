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
    // Use the button's attributedTitle directly when color matches, avoiding per-draw allocation.
    NSAttributedString* attrTitle = button ? button.attributedTitle : title;
    NSString* str = attrTitle.string ?: @"";
    if (str.length > 0)
    {
        NSDictionary* attrs = (str.length > 0) ? [attrTitle attributesAtIndex:0 effectiveRange:nil] : nil;
        NSColor* existingColor = attrs[NSForegroundColorAttributeName];
        if (existingColor && [existingColor isEqual:color])
        {
            [attrTitle drawInRect:frame];
        }
        else
        {
            NSMutableAttributedString* attr = [attrTitle mutableCopy];
            [attr addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, str.length)];
            [attr drawInRect:frame];
        }
    }
    return frame;
}

@end

@implementation PlayButton

+ (NSColor*)fillColorUnwatched:(BOOL)unwatched hovered:(BOOL)hovered
{
    // Cached static colors avoid repeated NSColor allocation on every draw.
    static NSColor* unwatchedHover;
    static NSColor* unwatchedNormal;
    static NSColor* watchedDarkHover;
    static NSColor* watchedDarkNormal;
    static NSColor* watchedLightHover;
    static NSColor* watchedLightNormal;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unwatchedHover = [NSColor colorWithCalibratedRed:0.2 green:0.54 blue:0.2 alpha:0.65];
        unwatchedNormal = [NSColor colorWithCalibratedRed:0.16 green:0.44 blue:0.16 alpha:0.6];
        watchedDarkHover = [NSColor colorWithCalibratedWhite:0.15 alpha:0.6];
        watchedDarkNormal = [NSColor colorWithCalibratedWhite:0.1 alpha:0.5];
        watchedLightHover = [NSColor colorWithCalibratedWhite:0.88 alpha:0.9];
        watchedLightNormal = [NSColor colorWithCalibratedWhite:0.82 alpha:0.85];
    });
    if (unwatched)
        return hovered ? unwatchedHover : unwatchedNormal;
    if (NSApp.darkMode)
        return hovered ? watchedDarkHover : watchedDarkNormal;
    return hovered ? watchedLightHover : watchedLightNormal;
}

+ (NSColor*)titleColorUnwatched:(BOOL)unwatched
{
    // Cached static colors avoid repeated NSColor allocation on every draw.
    static NSColor* unwatchedTitle;
    static NSColor* watchedDarkTitle;
    static NSColor* watchedLightTitle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unwatchedTitle = [NSColor colorWithCalibratedWhite:1.0 alpha:0.95];
        watchedDarkTitle = [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
        watchedLightTitle = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    });
    if (unwatched)
        return unwatchedTitle;
    if (NSApp.darkMode)
        return watchedDarkTitle;
    return watchedLightTitle;
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
        // Layer-backed for correct compositing in scrolled table cells.
        // RedrawDuringViewResize ensures content redraws when frame changes (fixes empty blocks after scroll).
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
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
}

- (void)setupTrackingArea
{
    NSTrackingArea* trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                                options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                                  owner:self
                                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
}

// NSTrackingInVisibleRect tracking areas auto-update; no need to recreate in updateTrackingAreas.

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
