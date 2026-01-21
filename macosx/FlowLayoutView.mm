// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "FlowLayoutView.h"

@implementation FlowLayoutView
{
    NSMutableArray<NSView*>* _arrangedSubviews;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if (self = [super initWithFrame:frameRect])
    {
        _arrangedSubviews = [NSMutableArray array];
        _horizontalSpacing = 6;
        _verticalSpacing = 2;
    }
    return self;
}

- (void)addArrangedSubview:(NSView*)view
{
    [_arrangedSubviews addObject:view];
    [self addSubview:view];
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
    [self invalidateIntrinsicContentSize];
}

- (void)layoutSubviewsForWidth:(CGFloat)availableWidth
{
    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat rowHeight = 0;

    for (NSView* view in _arrangedSubviews)
    {
        if (view.hidden)
            continue;

        NSSize size = view.intrinsicContentSize;
        if (size.width == NSViewNoIntrinsicMetric)
            size.width = view.fittingSize.width;
        if (size.height == NSViewNoIntrinsicMetric)
            size.height = view.fittingSize.height;
        if (size.width <= 0)
            size.width = 80;
        if (size.height <= 0)
            size.height = 18;

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
    CGFloat x = 0;
    CGFloat y = 0;
    CGFloat rowHeight = 0;

    for (NSView* view in _arrangedSubviews)
    {
        if (view.hidden)
            continue;

        NSSize size = view.intrinsicContentSize;
        if (size.width == NSViewNoIntrinsicMetric)
            size.width = view.fittingSize.width;
        if (size.height == NSViewNoIntrinsicMetric)
            size.height = view.fittingSize.height;
        if (size.width <= 0)
            size.width = 80;
        if (size.height <= 0)
            size.height = 18;

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
        if (!view.hidden)
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
    if (height < 18)
        height = 18;

    return NSMakeSize(NSViewNoIntrinsicMetric, height);
}

@end
