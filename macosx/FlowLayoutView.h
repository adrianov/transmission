// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

/// A view that arranges its subviews in a flow layout (left to right, wrapping to new lines).
/// Optimized with size caching to avoid redundant calculations during resize.
@interface FlowLayoutView : NSView

@property(nonatomic) CGFloat horizontalSpacing;
@property(nonatomic) CGFloat verticalSpacing;

- (void)addArrangedSubview:(NSView*)view;
- (NSArray<NSView*>*)arrangedSubviews;

/// Returns cached height for given width. Only recalculates if width changed or cache invalidated.
- (CGFloat)heightForWidth:(CGFloat)width;

/// Invalidates the cached layout. Call when subview content changes (e.g., button title).
- (void)invalidateLayoutCache;

@end
