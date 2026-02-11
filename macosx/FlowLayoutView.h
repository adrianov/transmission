// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

/// Arranges subviews as a vertical stack of horizontal stacks (rows). Line breaks force a new row;
/// otherwise items fill rows left-to-right and wrap when width is exceeded. Layout is done by NSStackView.
@interface FlowLayoutView : NSView

@property(nonatomic) CGFloat horizontalSpacing;
@property(nonatomic) CGFloat verticalSpacing;
/// Minimum width for buttons (default 50)
@property(nonatomic) CGFloat minimumButtonWidth;
/// Max items per row (0 = no cap)
@property(nonatomic) NSUInteger maximumColumnCount;

- (void)addArrangedSubview:(NSView*)view;
- (void)addArrangedSubviewBatched:(NSView*)view;
- (void)addLineBreak;
- (void)addLineBreakBatched;
- (void)finishBatchUpdates;
- (NSArray<NSView*>*)arrangedSubviews;

/// Returns height for given width. Uses cached sizes for subviews.
- (CGFloat)heightForWidth:(CGFloat)width;
/// Last computed height (valid when layout not dirty and width matches lastLayoutWidth). Use to avoid redraw when reusing.
@property(nonatomic, readonly) CGFloat lastLayoutHeight;
@property(nonatomic, readonly) CGFloat lastLayoutWidth;
/// YES when lastLayoutHeight can be used for this width without recomputing (avoids layout/redraw).
- (BOOL)hasValidLayoutForWidth:(CGFloat)width;

/// Removes all arranged subviews efficiently.
- (void)removeAllArrangedSubviews;

/// Clears cached size for a specific view (call when view content changes)
- (void)invalidateSizeForView:(NSView*)view;
/// Clears cached layout/height (call when visibility changes)
- (void)invalidateLayoutCache;

@end
