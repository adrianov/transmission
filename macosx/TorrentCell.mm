// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCell.h"
#import "PlayButton.h"
#import "ProgressBarView.h"
#import "ProgressGradients.h"
#import "Torrent.h"
#import "NSImageAdditions.h"

@implementation TorrentCell

- (void)awakeFromNib
{
    [super awakeFromNib];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    if (self.fTorrentTableView)
        [self.fTorrentTableView hoverEventBeganForView:self];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    if (self.fTorrentTableView)
        [self.fTorrentTableView hoverEventEndedForView:self];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (self.fHoverTrackingArea)
    {
        [self removeTrackingArea:self.fHoverTrackingArea];
        self.fHoverTrackingArea = nil;
    }
    if (self.fHoverButtonsTrackingArea)
    {
        [self removeTrackingArea:self.fHoverButtonsTrackingArea];
        self.fHoverButtonsTrackingArea = nil;
    }
    NSRect iconRect = self.fIconView ? self.fIconView.frame : NSZeroRect;
    NSRect buttonsRect = NSZeroRect;
    for (NSView* v in @[ self.fActionButton, self.fControlButton, self.fRevealButton, self.fURLButton ])
        if (v)
            buttonsRect = NSUnionRect(buttonsRect, v.frame);
    NSRect hoverRect = NSIsEmptyRect(iconRect) ? self.bounds : iconRect;
    self.fHoverTrackingArea = [[NSTrackingArea alloc] initWithRect:hoverRect
                                                            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                                              owner:self
                                                           userInfo:nil];
    [self addTrackingArea:self.fHoverTrackingArea];
    if (!NSIsEmptyRect(buttonsRect))
    {
        self.fHoverButtonsTrackingArea = [[NSTrackingArea alloc] initWithRect:buttonsRect
                                                                      options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                                                        owner:self
                                                                     userInfo:nil];
        [self addTrackingArea:self.fHoverButtonsTrackingArea];
    }
}

- (BOOL)wantsUpdateLayer
{
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect
{
    if (self.fTorrentTableView)
    {
        Torrent* torrent = [self.objectValue isKindOfClass:[Torrent class]] ? (Torrent*)self.objectValue : nil;
        if (torrent)
        {
            // draw progress bar - use cached image when possible
            NSRect barRect = self.fTorrentProgressBarView.frame;
            if (barRect.size.width > 0 && barRect.size.height > 0)
            {
                // Cache key must include piecesBarPercent so toggling View → Pieces Bar invalidates cache (regression fix).
                CGFloat const piecesPercent = self.fTorrentTableView.piecesBarPercent;
                NSString* cacheKey = [NSString stringWithFormat:@"%@_%f_%d_%d_%f_%f_%d_%f_%d_%f",
                                                                torrent.hashString,
                                                                torrent.progress,
                                                                torrent.active,
                                                                torrent.checking,
                                                                torrent.progressLeft,
                                                                torrent.availableDesired,
                                                                torrent.seeding,
                                                                torrent.progressStopRatio,
                                                                torrent.allDownloaded,
                                                                piecesPercent];

                // Check if we need to regenerate the progress bar image
                if (!self.fCachedProgressBarImage || ![self.fProgressBarCacheKey isEqualToString:cacheKey] ||
                    !NSEqualSizes(self.fCachedProgressBarImage.size, barRect.size))
                {
                    self.fCachedProgressBarImage = [NSImage imageWithSize:barRect.size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
                        ProgressBarView* progressBar = [[ProgressBarView alloc] init];
                        [progressBar drawBarInRect:dstRect forTableView:self.fTorrentTableView withTorrent:torrent];
                        return YES;
                    }];
                    self.fProgressBarCacheKey = cacheKey;
                }

                // Draw cached progress bar image
                [self.fCachedProgressBarImage drawInRect:barRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                                fraction:1.0];
            }

            // set priority icon
            if (torrent.priority != TR_PRI_NORMAL)
            {
                NSColor* priorityColor = self.backgroundStyle == NSBackgroundStyleEmphasized ? NSColor.whiteColor : NSColor.labelColor;
                NSImage* priorityImage = [[NSImage imageNamed:(torrent.priority == TR_PRI_HIGH ? @"PriorityHighTemplate" : @"PriorityLowTemplate")]
                    imageWithColor:priorityColor];

                self.fTorrentPriorityView.image = priorityImage;

                [self.fStackView setVisibilityPriority:NSStackViewVisibilityPriorityMustHold forView:self.fTorrentPriorityView];
            }
            else
            {
                [self.fStackView setVisibilityPriority:NSStackViewVisibilityPriorityNotVisible forView:self.fTorrentPriorityView];
            }
        }
    }

    [super drawRect:dirtyRect];
}

// otherwise progress bar is inverted
- (BOOL)isFlipped
{
    return YES;
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle
{
    [super setBackgroundStyle:backgroundStyle];

    BOOL emphasized = (backgroundStyle == NSBackgroundStyleEmphasized);
    NSColor* primaryColor = emphasized ? NSColor.whiteColor : NSColor.labelColor;
    NSColor* secondaryColor = emphasized ? NSColor.whiteColor : NSColor.secondaryLabelColor;

    if (self.fTorrentTitleField)
        self.fTorrentTitleField.textColor = primaryColor;
    if (self.fTorrentProgressField)
        self.fTorrentProgressField.textColor = secondaryColor;
    if (self.fTorrentStatusField)
        self.fTorrentStatusField.textColor = secondaryColor;

    if (self.fPlayButtonsView)
    {
        NSColor* defaultButtonTextColor = NSColor.secondaryLabelColor;
        for (NSView* subview in self.fPlayButtonsView.subviews)
        {
            if ([subview isKindOfClass:[PlayButton class]])
            {
                PlayButton* button = (PlayButton*)subview;
                NSColor* buttonTextColor = [PlayButton titleColorUnwatched:button.iinaUnwatched];
                NSString* title = button.title ?: @"";
                NSMutableAttributedString* attrTitle = [[NSMutableAttributedString alloc] initWithString:title];
                [attrTitle addAttribute:NSForegroundColorAttributeName value:buttonTextColor range:NSMakeRange(0, title.length)];
                [attrTitle addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:11] range:NSMakeRange(0, title.length)];
                button.attributedTitle = attrTitle;
                if (button.cell)
                    button.cell.backgroundStyle = backgroundStyle;
            }
            else if ([subview isKindOfClass:[NSTextField class]])
                ((NSTextField*)subview).textColor = defaultButtonTextColor;
        }
    }
}

- (void)invalidateProgressBarCache
{
    self.fCachedProgressBarImage = nil;
    self.fProgressBarCacheKey = nil;
}

- (void)configureCollectionView
{
    // Method declared but not implemented - placeholder to satisfy compiler
}

- (void)setObjectValue:(id)objectValue
{
    [super setObjectValue:objectValue];

    // Invalidate cache when cell is reused for different torrent
    Torrent* torrent = (Torrent*)objectValue;
    if (torrent && ![torrent.hashString isEqualToString:self.fTorrentHash])
    {
        [self invalidateProgressBarCache];
        self.fTorrentHash = torrent.hashString;
    }
}

@end
