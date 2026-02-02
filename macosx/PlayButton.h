// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

/// Custom button for play controls. Green fill (theme-friendly, slightly darker); hover brightens.
@interface PlayButton : NSButton

/// Fill color for bezel. Slightly darker green (theme-friendly); hovered variant is brighter.
+ (NSColor*)fillColorUnwatched:(BOOL)unwatched hovered:(BOOL)hovered;

/// Title color for current state. Green (unwatched) = light on green; gray (watched) = theme-consistent (light text in dark, dark in light).
+ (NSColor*)titleColorUnwatched:(BOOL)unwatched;

@property(nonatomic) BOOL isHovered;
@property(nonatomic) BOOL iinaUnwatched;
@property(nonatomic, copy) void (^onHover)(PlayButton* button);

/// Resets the button state for reuse in a pool.
- (void)prepareForReuse;

@end
