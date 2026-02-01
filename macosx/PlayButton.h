// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

/// Custom button for play controls with darker hover background.
/// Fill color: unwatched (IINA) = green, watched = gray; hover brightens.
@interface PlayButton : NSButton

/// Fill color for bezel. Unwatched → green; watched → gray. Hovered variant is brighter.
+ (NSColor*)fillColorUnwatched:(BOOL)unwatched hovered:(BOOL)hovered;

@property(nonatomic) BOOL isHovered;
@property(nonatomic) BOOL iinaUnwatched;
@property(nonatomic, copy) void (^onHover)(PlayButton* button);

/// Resets the button state for reuse in a pool.
- (void)prepareForReuse;

@end
