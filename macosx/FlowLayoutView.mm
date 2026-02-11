// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import "FlowLayoutView.h"
#import <QuartzCore/CALayer.h>

@interface FlowLineBreak : NSView
@end

@implementation FlowLineBreak

- (BOOL)isOpaque
{
    return NO;
}

@end

@implementation FlowLayoutView
{
    NSMutableArray<NSView*>* _arrangedSubviews;
    NSMapTable<NSView*, NSValue*>* _cachedSizes;
    NSArray<NSView*>* _visibleSubviewsCache;
    BOOL _visibleCacheValid;
    BOOL _layoutDirty;
    CGFloat _lastLayoutWidth;
    CGFloat _lastLayoutHeight;
    NSStackView* _verticalStack;
    NSMutableArray<NSStackView*>* _rowStacks;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if (self = [super initWithFrame:frameRect])
    {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

        _arrangedSubviews = [NSMutableArray array];
        _cachedSizes = [NSMapTable weakToStrongObjectsMapTable];
        _horizontalSpacing = 6;
        _verticalSpacing = 4;
        _minimumButtonWidth = 50;
        _visibleCacheValid = NO;
        _layoutDirty = YES;
        _lastLayoutWidth = 0;
        _lastLayoutHeight = 0;
        _rowStacks = [NSMutableArray array];

        _verticalStack = [[NSStackView alloc] init];
        _verticalStack.translatesAutoresizingMaskIntoConstraints = NO;
        _verticalStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        _verticalStack.alignment = NSLayoutAttributeLeading;
        _verticalStack.distribution = NSStackViewDistributionGravityAreas;
        _verticalStack.spacing = 4;
        [self addSubview:_verticalStack];
    }
    return self;
}

// Regression fix: FlowLayoutView is layer-backed but draws no content of its own.
// Without explicit transparency, the backing layer can render as a black rectangle
// during transitional states (e.g. async button computation while scrolling).
// All three overrides are needed: isOpaque tells AppKit the view is transparent,
// wantsDefaultClipping avoids stale clipping rects, and makeBackingLayer ensures
// the CALayer itself has no background fill.
- (BOOL)isOpaque
{
    return NO;
}

- (BOOL)wantsDefaultClipping
{
    return NO;
}

- (CALayer*)makeBackingLayer
{
    CALayer* layer = [super makeBackingLayer];
    layer.backgroundColor = nil;
    layer.opaque = NO;
    return layer;
}

- (void)addArrangedSubview:(NSView*)view
{
    [_arrangedSubviews addObject:view];
    [self addSubview:view];
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    // Don't trigger layout for each view - let caller batch updates
}

- (void)addArrangedSubviewBatched:(NSView*)view
{
    [_arrangedSubviews addObject:view];
    [self addSubview:view];
    // No cache invalidation - caller will call finishBatchUpdates
}

- (void)finishBatchUpdates
{
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)addLineBreak
{
    FlowLineBreak* br = [[FlowLineBreak alloc] init];
    [_arrangedSubviews addObject:br];
    [self addSubview:br];
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    // Don't trigger layout for each view - let caller batch updates
}

- (void)addLineBreakBatched
{
    FlowLineBreak* br = [[FlowLineBreak alloc] init];
    [_arrangedSubviews addObject:br];
    [self addSubview:br];
    // No cache invalidation - caller will call finishBatchUpdates
}

- (NSArray<NSView*>*)arrangedSubviews
{
    return [_arrangedSubviews copy];
}

- (void)removeAllArrangedSubviews
{
    if (_arrangedSubviews.count == 0)
        return;

    for (NSView* view in _arrangedSubviews)
        [view removeFromSuperview];
    [_arrangedSubviews removeAllObjects];
    for (NSStackView* rowStack in _rowStacks)
    {
        for (NSView* v in [rowStack.arrangedSubviews copy])
            [rowStack removeArrangedSubview:v];
    }
    for (NSView* v in [_verticalStack.arrangedSubviews copy])
        [_verticalStack removeArrangedSubview:v];
    [_cachedSizes removeAllObjects];
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    _lastLayoutWidth = 0;
    _lastLayoutHeight = 0;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped
{
    return YES;
}

- (void)setBounds:(NSRect)bounds
{
    [super setBounds:bounds];
    CGFloat w = bounds.size.width;
    if (w > 0 && (std::fabs(w - _lastLayoutWidth) > 0.001 || _layoutDirty))
        [self setNeedsLayout:YES];
}

- (void)layout
{
    [super layout];
    CGFloat width = self.bounds.size.width;
    if (width <= 0 && self.superview)
        width = self.superview.bounds.size.width;
    [self syncStackRowsForWidth:width];
}

- (NSSize)sizeForView:(NSView*)view
{
    NSValue* cached = [_cachedSizes objectForKey:view];
    if (cached)
        return cached.sizeValue;

    NSSize size;
    if ([view isKindOfClass:[NSButton class]])
    {
        // For buttons, use intrinsicContentSize + fixed padding to avoid expensive cellSizeForBounds
        size = view.intrinsicContentSize;
        size.width += 10; // Padding for recessed style
        if (size.width < _minimumButtonWidth)
            size.width = _minimumButtonWidth;
    }
    else
    {
        size = view.fittingSize;
    }

    if (size.width <= 0)
        size.width = 60;
    if (size.height <= 0)
        size.height = 18;

    [_cachedSizes setObject:[NSValue valueWithSize:size] forKey:view];
    return size;
}

- (NSArray<NSView*>*)visibleArrangedSubviews
{
    if (_visibleCacheValid)
        return _visibleSubviewsCache;

    NSMutableArray<NSView*>* visible = [NSMutableArray array];
    for (NSView* view in _arrangedSubviews)
    {
        if (!view.hidden)
            [visible addObject:view];
    }
    _visibleSubviewsCache = [visible copy];
    _visibleCacheValid = YES;
    return _visibleSubviewsCache;
}

/// Partitions visible subviews into rows by flow: left-to-right until width overflows, then next row. Line breaks force new row.
- (NSArray<NSArray<NSView*>*>*)rowsForWidth:(CGFloat)availableWidth
{
    NSMutableArray<NSArray<NSView*>*>* rows = [NSMutableArray array];
    NSMutableArray<NSView*>* currentRow = [NSMutableArray array];
    CGFloat currentX = 0;

    for (NSView* view in [self visibleArrangedSubviews])
    {
        if ([view isKindOfClass:[FlowLineBreak class]])
        {
            if (currentRow.count > 0)
            {
                [rows addObject:[currentRow copy]];
                [currentRow removeAllObjects];
            }
            currentX = 0;
            continue;
        }
        CGFloat w = [self sizeForView:view].width;
        BOOL overflow = (currentX + w > availableWidth + 0.001) && currentRow.count > 0;
        BOOL atCap = _maximumColumnCount > 0 && currentRow.count >= _maximumColumnCount;
        if ((overflow || atCap) && currentRow.count > 0)
        {
            [rows addObject:[currentRow copy]];
            [currentRow removeAllObjects];
            currentX = 0;
        }
        [currentRow addObject:view];
        currentX += w + _horizontalSpacing;
    }
    if (currentRow.count > 0)
        [rows addObject:currentRow];

    return rows;
}

/// Syncs row stacks with rowsForWidth and lets NSStackView handle layout.
- (void)syncStackRowsForWidth:(CGFloat)availableWidth
{
    if (availableWidth <= 0)
        return;
    if (!_layoutDirty && std::fabs(availableWidth - _lastLayoutWidth) < 0.001)
        return;

    NSRect bounds = self.bounds;
    if (!NSEqualRects(_verticalStack.frame, bounds))
        _verticalStack.frame = bounds;
    if (std::fabs(_verticalStack.spacing - _verticalSpacing) > 0.001)
        _verticalStack.spacing = _verticalSpacing;

    NSArray<NSArray<NSView*>*>* rows = [self rowsForWidth:availableWidth];
    while (_rowStacks.count < rows.count)
    {
        NSStackView* rowStack = [[NSStackView alloc] init];
        rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        rowStack.alignment = NSLayoutAttributeCenterY;
        rowStack.distribution = NSStackViewDistributionGravityAreas;
        rowStack.spacing = _horizontalSpacing;
        [_rowStacks addObject:rowStack];
    }
    NSUInteger r = 0;
    for (NSArray<NSView*>* row in rows)
    {
        NSStackView* rowStack = _rowStacks[r++];
        if (![rowStack.arrangedSubviews isEqualToArray:row])
        {
            for (NSView* v in [rowStack.arrangedSubviews copy])
            {
                [rowStack removeArrangedSubview:v];
                [self addSubview:v];
            }
            for (NSView* v in row)
            {
                [v removeFromSuperview];
                [rowStack addArrangedSubview:v];
            }
        }
    }
    for (NSUInteger i = rows.count; i < _rowStacks.count; i++)
    {
        NSStackView* rowStack = _rowStacks[i];
        for (NSView* v in [rowStack.arrangedSubviews copy])
        {
            [rowStack removeArrangedSubview:v];
            [self addSubview:v];
        }
    }
    // Vertical stack must show first row at top: arranged order = _rowStacks[0], _rowStacks[1], ...
    NSArray* currentStacks = _verticalStack.arrangedSubviews;
    BOOL orderMatches = currentStacks.count == rows.count;
    if (orderMatches)
        for (NSUInteger i = 0; i < rows.count; i++)
            if (currentStacks[i] != _rowStacks[i])
            {
                orderMatches = NO;
                break;
            }
    if (!orderMatches)
    {
        for (NSView* v in currentStacks)
            [v removeFromSuperview];
        for (NSUInteger i = 0; i < rows.count; i++)
            [_verticalStack addArrangedSubview:_rowStacks[i]];
    }

    CGFloat y = 0;
    for (NSArray<NSView*>* row in rows)
    {
        CGFloat rowHeight = 0;
        for (NSView* view in row)
            rowHeight = MAX(rowHeight, [self sizeForView:view].height);
        y += rowHeight + _verticalSpacing;
    }
    _lastLayoutHeight = rows.count > 0 ? y - _verticalSpacing : 0;
    _layoutDirty = NO;
    _lastLayoutWidth = availableWidth;
}

- (CGFloat)lastLayoutHeight
{
    return _lastLayoutHeight;
}

- (CGFloat)lastLayoutWidth
{
    return _lastLayoutWidth;
}

- (BOOL)hasValidLayoutForWidth:(CGFloat)width
{
    return !_layoutDirty && width > 0 && std::fabs(width - _lastLayoutWidth) < 0.001;
}

- (CGFloat)heightForWidth:(CGFloat)availableWidth
{
    if (availableWidth <= 0)
        return 0;
    if (!_layoutDirty && std::fabs(availableWidth - _lastLayoutWidth) < 0.001)
        return _lastLayoutHeight;
    [self syncStackRowsForWidth:availableWidth];
    return _lastLayoutHeight;
}

- (NSSize)intrinsicContentSize
{
    BOOL hasVisible = NO;
    for (NSView* view in [self visibleArrangedSubviews])
        if (![view isKindOfClass:[FlowLineBreak class]])
        {
            hasVisible = YES;
            break;
        }
    if (!hasVisible)
        return NSMakeSize(NSViewNoIntrinsicMetric, 0);

    CGFloat width = self.bounds.size.width;
    if (width < 100)
        width = self.superview ? self.superview.bounds.size.width : 600;
    if (width < 100)
        width = 600;

    CGFloat height = [self heightForWidth:width];
    return NSMakeSize(NSViewNoIntrinsicMetric, MAX(height, 0));
}

- (void)invalidateSizeForView:(NSView*)view
{
    [_cachedSizes removeObjectForKey:view];
    _visibleCacheValid = NO;
    _layoutDirty = YES;
}

- (void)invalidateLayoutCache
{
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    [self setNeedsLayout:YES];
}

@end
