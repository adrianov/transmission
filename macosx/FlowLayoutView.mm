// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import "FlowLayoutView.h"

@interface FlowLineBreak : NSView
@end

@implementation FlowLineBreak
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
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if (self = [super initWithFrame:frameRect])
    {
        _arrangedSubviews = [NSMutableArray array];
        _cachedSizes = [NSMapTable weakToStrongObjectsMapTable];
        _horizontalSpacing = 6;
        _verticalSpacing = 4;
        _minimumButtonWidth = 50;
        _visibleCacheValid = NO;
        _layoutDirty = YES;
        _lastLayoutWidth = 0;
        _lastLayoutHeight = 0;
    }
    return self;
}

- (void)addArrangedSubview:(NSView*)view
{
    [_arrangedSubviews addObject:view];
    [self addSubview:view];
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    [self setNeedsLayout:YES];
}

- (void)addLineBreak
{
    FlowLineBreak* br = [[FlowLineBreak alloc] init];
    [_arrangedSubviews addObject:br];
    [self addSubview:br];
    _visibleCacheValid = NO;
    _layoutDirty = YES;
    [self setNeedsLayout:YES];
}

- (NSArray<NSView*>*)arrangedSubviews
{
    return [_arrangedSubviews copy];
}

- (BOOL)isFlipped
{
    return YES;
}

- (void)layout
{
    [super layout];
    [self layoutSubviewsForWidth:self.bounds.size.width];
}

- (NSSize)sizeForView:(NSView*)view
{
    NSValue* cached = [_cachedSizes objectForKey:view];
    if (cached)
        return cached.sizeValue;

    NSSize size = view.fittingSize;
    if ([view isKindOfClass:[NSButton class]])
    {
        // Use cellSize for buttons to ensure we get the full width including image and title
        NSButton* button = (NSButton*)view;
        size = [button.cell cellSizeForBounds:NSMakeRect(0, 0, 10000, 10000)];
        size.width += 6; // Add minimal padding for the recessed bezel
    }

    if (size.width <= 0)
        size.width = 60;
    if (size.height <= 0)
        size.height = 18;

    // Apply minimum width for buttons
    if ([view isKindOfClass:[NSButton class]] && size.width < _minimumButtonWidth)
        size.width = _minimumButtonWidth;

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
        {
            [visible addObject:view];
        }
    }
    _visibleSubviewsCache = [visible copy];
    _visibleCacheValid = YES;
    return _visibleSubviewsCache;
}

- (void)layoutSubviewsForWidth:(CGFloat)availableWidth
{
    if (availableWidth <= 0)
        return;
    if (!_layoutDirty && std::fabs(availableWidth - _lastLayoutWidth) < 0.001)
        return;

    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat rowHeight = 0;

    for (NSView* view in [self visibleArrangedSubviews])
    {
        if ([view isKindOfClass:[FlowLineBreak class]])
        {
            y += rowHeight + (rowHeight > 0 ? _verticalSpacing : 0);
            rowHeight = 0;
            x = 0;
            continue;
        }

        NSSize size = [self sizeForView:view];
        size.width = MIN(size.width, availableWidth);

        // Wrap to next line if needed
        if (x > 0 && x + size.width > availableWidth)
        {
            x = 0;
            y += rowHeight + _verticalSpacing;
            rowHeight = 0;
        }

        view.frame = NSMakeRect(x, y, size.width, size.height);
        x += size.width + _horizontalSpacing;
        rowHeight = MAX(rowHeight, size.height);
    }

    _layoutDirty = NO;
    _lastLayoutWidth = availableWidth;
    _lastLayoutHeight = y + rowHeight;
}

- (CGFloat)heightForWidth:(CGFloat)availableWidth
{
    if (availableWidth <= 0)
        return 0;
    if (!_layoutDirty && std::fabs(availableWidth - _lastLayoutWidth) < 0.001)
        return _lastLayoutHeight;

    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat rowHeight = 0;

    for (NSView* view in [self visibleArrangedSubviews])
    {
        if ([view isKindOfClass:[FlowLineBreak class]])
        {
            x = 0;
            y += rowHeight + (rowHeight > 0 ? _verticalSpacing : 0);
            rowHeight = 0;
            continue;
        }

        NSSize size = [self sizeForView:view];
        size.width = MIN(size.width, availableWidth);

        if (x > 0 && x + size.width > availableWidth)
        {
            x = 0;
            y += rowHeight + _verticalSpacing;
            rowHeight = 0;
        }

        x += size.width + _horizontalSpacing;
        rowHeight = MAX(rowHeight, size.height);
    }

    _lastLayoutWidth = availableWidth;
    _lastLayoutHeight = y + rowHeight;
    return _lastLayoutHeight;
}

- (NSSize)intrinsicContentSize
{
    BOOL hasVisible = NO;
    for (NSView* view in [self visibleArrangedSubviews])
    {
        if (!view.hidden && ![view isKindOfClass:[FlowLineBreak class]])
        {
            hasVisible = YES;
            break;
        }
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
