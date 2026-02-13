// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import "FlowLayoutView.h"

@interface FlowLineBreak : NSView
@end

@implementation FlowLineBreak
- (BOOL)isOpaque { return NO; }
@end

@interface FlowLayoutView ()
@property(nonatomic) NSMutableArray<NSView*>* contentViews;
@property(nonatomic) NSMapTable<NSView*, NSValue*>* cachedSizes;
@property(nonatomic) CGFloat lastLayoutWidth;
@property(nonatomic) CGFloat lastLayoutHeight;
@property(nonatomic) BOOL layoutDirty;
@end

@implementation FlowLayoutView

- (void)commonInit
{
    self.translatesAutoresizingMaskIntoConstraints = NO;
    // Non-layer-backed: avoids layer caching that causes empty blocks after scroll.
    // Subviews (PlayButton) remain layer-backed; that combination works correctly.
    self.wantsLayer = NO;

    _contentViews = [NSMutableArray array];
    _cachedSizes = [NSMapTable weakToStrongObjectsMapTable];
    _horizontalSpacing = 6;
    _verticalSpacing = 4;
    _minimumButtonWidth = 50;
    _layoutDirty = YES;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self)
        [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder*)coder
{
    self = [super initWithCoder:coder];
    if (self)
        [self commonInit];
    return self;
}

- (BOOL)isOpaque { return NO; }

- (BOOL)isFlipped { return YES; }

- (void)addArrangedSubview:(NSView*)view
{
    [_contentViews addObject:view];
    [self addSubview:view];
    _layoutDirty = YES;
}

- (void)addArrangedSubviewBatched:(NSView*)view
{
    [_contentViews addObject:view];
    [self addSubview:view];
}

- (void)finishBatchUpdates
{
    _layoutDirty = YES;
    [self setNeedsLayout:YES];
}

- (void)addLineBreak
{
    FlowLineBreak* br = [[FlowLineBreak alloc] init];
    [_contentViews addObject:br];
    [self addSubview:br];
    _layoutDirty = YES;
}

- (void)addLineBreakBatched
{
    FlowLineBreak* br = [[FlowLineBreak alloc] init];
    [_contentViews addObject:br];
    [self addSubview:br];
}

- (NSArray<NSView*>*)contentSubviews
{
    return [_contentViews copy];
}

- (void)removeAllArrangedSubviews
{
    if (_contentViews.count == 0)
        return;
    for (NSView* v in _contentViews)
        [v removeFromSuperview];
    [_contentViews removeAllObjects];
    [_cachedSizes removeAllObjects];
    _layoutDirty = YES;
    _lastLayoutWidth = 0;
    _lastLayoutHeight = 0;
    [self invalidateIntrinsicContentSize];
}

- (NSSize)sizeForView:(NSView*)view
{
    NSValue* cached = [_cachedSizes objectForKey:view];
    if (cached)
        return cached.sizeValue;
    NSSize size;
    if ([view isKindOfClass:[NSButton class]])
    {
        size = view.intrinsicContentSize;
        size.width += 10;
        if (size.width < _minimumButtonWidth)
            size.width = _minimumButtonWidth;
    }
    else
        size = view.fittingSize;
    if (size.width <= 0) size.width = 60;
    if (size.height <= 0) size.height = 18;
    [_cachedSizes setObject:[NSValue valueWithSize:size] forKey:view];
    return size;
}

- (NSArray<NSArray<NSView*>*>*)rowsForWidth:(CGFloat)width
{
    NSMutableArray<NSArray<NSView*>*>* rows = [NSMutableArray array];
    NSMutableArray<NSView*>* currentRow = [NSMutableArray array];
    CGFloat x = 0;

    for (NSView* v in _contentViews)
    {
        if ([v isKindOfClass:[FlowLineBreak class]])
        {
            if (currentRow.count > 0)
            {
                [rows addObject:[currentRow copy]];
                [currentRow removeAllObjects];
            }
            x = 0;
            continue;
        }
        if (v.hidden)
            continue;
        CGFloat w = [self sizeForView:v].width;
        BOOL overflow = (x + w > width + 0.001) && currentRow.count > 0;
        BOOL atCap = _maximumColumnCount > 0 && currentRow.count >= _maximumColumnCount;
        if ((overflow || atCap) && currentRow.count > 0)
        {
            [rows addObject:[currentRow copy]];
            [currentRow removeAllObjects];
            x = 0;
        }
        [currentRow addObject:v];
        x += w + _horizontalSpacing;
    }
    if (currentRow.count > 0)
        [rows addObject:currentRow];
    return rows;
}

- (void)applyLayoutForWidth:(CGFloat)width
{
    if (width <= 0) return;
    if (!_layoutDirty && std::fabs(width - _lastLayoutWidth) < 0.001) return;

    NSArray<NSArray<NSView*>*>* rows = [self rowsForWidth:width];
    CGFloat y = 0;

    for (NSView* v in _contentViews)
        if ([v isKindOfClass:[FlowLineBreak class]])
        {
            v.hidden = YES;
            v.frame = NSZeroRect;
        }
    for (NSArray* row in rows)
    {
        CGFloat rowH = 0;
        for (NSView* v in row)
            rowH = MAX(rowH, [self sizeForView:v].height);
        CGFloat x = 0;
        for (NSView* v in row)
        {
            NSSize sz = [self sizeForView:v];
            v.hidden = NO;
            CGFloat vY = y + (rowH - sz.height) / 2.0;
            NSRect newFrame = NSMakeRect(x, vY, sz.width, sz.height);
            // Only mark dirty if frame actually changed; avoids redundant redraws during scroll.
            if (!NSEqualRects(v.frame, newFrame))
                v.frame = newFrame;
            x += sz.width + _horizontalSpacing;
        }
        y += rowH + _verticalSpacing;
    }

    _lastLayoutHeight = rows.count > 0 ? y - _verticalSpacing : 0;
    _layoutDirty = NO;
    _lastLayoutWidth = width;
}

- (void)layout
{
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    if (width <= 0 && self.superview)
        width = NSWidth(self.superview.bounds);
    [self applyLayoutForWidth:width];
}

- (CGFloat)heightForWidth:(CGFloat)width
{
    if (width <= 0) return 0;
    if (!_layoutDirty && std::fabs(width - _lastLayoutWidth) < 0.001)
        return _lastLayoutHeight;
    [self applyLayoutForWidth:width];
    return _lastLayoutHeight;
}

- (BOOL)hasValidLayoutForWidth:(CGFloat)width
{
    return !_layoutDirty && width > 0 && std::fabs(width - _lastLayoutWidth) < 0.001;
}

- (NSSize)intrinsicContentSize
{
    BOOL hasVisible = NO;
    for (NSView* v in _contentViews)
        if (![v isKindOfClass:[FlowLineBreak class]] && !v.hidden)
        {
            hasVisible = YES;
            break;
        }
    if (!hasVisible)
        return NSMakeSize(NSViewNoIntrinsicMetric, 0);
    CGFloat w = NSWidth(self.bounds);
    if (w < 100)
        w = self.superview ? NSWidth(self.superview.bounds) : 600;
    if (w < 100) w = 600;
    return NSMakeSize(NSViewNoIntrinsicMetric, MAX([self heightForWidth:w], 0));
}

- (void)invalidateSizeForView:(NSView*)view
{
    [_cachedSizes removeObjectForKey:view];
    _layoutDirty = YES;
}

- (void)invalidateLayoutCache
{
    _layoutDirty = YES;
    [self setNeedsLayout:YES];
}

@end
