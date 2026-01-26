// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

/// A view that arranges its subviews in a flow layout (left to right, wrapping to new lines).
/// Buttons size to their content with minimum padding.
@interface FlowLayoutView : NSView

@property(nonatomic) CGFloat horizontalSpacing;
@property(nonatomic) CGFloat verticalSpacing;
/// Minimum width for buttons (default 50)
@property(nonatomic) CGFloat minimumButtonWidth;

- (void)addArrangedSubview:(NSView*)view;
- (void)addArrangedSubviewBatched:(NSView*)view;
- (void)addLineBreak;
- (void)addLineBreakBatched;
- (void)finishBatchUpdates;
- (NSArray<NSView*>*)arrangedSubviews;

/// Returns height for given width. Uses cached sizes for subviews.
- (CGFloat)heightForWidth:(CGFloat)width;

/// Removes all arranged subviews efficiently.
- (void)removeAllArrangedSubviews;

/// Clears cached size for a specific view (call when view content changes)
- (void)invalidateSizeForView:(NSView*)view;
/// Clears cached layout/height (call when visibility changes)
- (void)invalidateLayoutCache;

@end
