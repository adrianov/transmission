// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "FlowLayoutView.h"

@interface FlowLineBreak : NSView
@end

@implementation FlowLineBreak
@end

@implementation FlowLayoutView
{
    NSMutableArray<NSView*>* _arrangedSubviews;
    NSMapTable<NSView*, NSValue*>* _cachedSizes;
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
    }
    return self;
}

- (void)addArrangedSubview:(NSView*)view
{
    [_arrangedSubviews addObject:view];
    [self addSubview:view];
    [self setNeedsLayout:YES];
}

- (void)addLineBreak
{
    FlowLineBreak* br = [[FlowLineBreak alloc] init];
    [_arrangedSubviews addObject:br];
    [self addSubview:br];
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

- (void)layoutSubviewsForWidth:(CGFloat)availableWidth
{
    if (availableWidth <= 0)
        return;

    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat rowHeight = 0;

    for (NSView* view in _arrangedSubviews)
    {
        if (view.hidden)
            continue;

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
}

- (CGFloat)heightForWidth:(CGFloat)availableWidth
{
    if (availableWidth <= 0)
        return 0;

    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat rowHeight = 0;

    for (NSView* view in _arrangedSubviews)
    {
        if (view.hidden)
            continue;

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

    return y + rowHeight;
}

- (NSSize)intrinsicContentSize
{
    BOOL hasVisible = NO;
    for (NSView* view in _arrangedSubviews)
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

@end
