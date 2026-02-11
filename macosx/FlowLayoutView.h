// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

/// Vertical stack of horizontal stacks. Line breaks force new row; items flow left-to-right and wrap when width exceeded.
@interface FlowLayoutView : NSView

@property(nonatomic) CGFloat horizontalSpacing;
@property(nonatomic) CGFloat verticalSpacing;
@property(nonatomic) CGFloat minimumButtonWidth;
@property(nonatomic) NSUInteger maximumColumnCount;

- (void)addArrangedSubview:(NSView*)view;
- (void)addArrangedSubviewBatched:(NSView*)view;
- (void)addLineBreak;
- (void)addLineBreakBatched;
- (void)finishBatchUpdates;
- (NSArray<NSView*>*)contentSubviews;

- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, readonly) CGFloat lastLayoutHeight;
@property(nonatomic, readonly) CGFloat lastLayoutWidth;
- (BOOL)hasValidLayoutForWidth:(CGFloat)width;

- (void)removeAllArrangedSubviews;
- (void)invalidateSizeForView:(NSView*)view;
- (void)invalidateLayoutCache;

@end
