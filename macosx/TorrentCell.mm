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
    // 1. Enable layers for GPU-accelerated scrolling
    self.wantsLayer = YES;
    // 2. Flatten subviews to reduce layer count (improves FPS)
    self.canDrawSubviewsIntoLayer = YES;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    // Background styling: keep clear so the table view controls row backgrounds.
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
}

- (void)drawRect:(NSRect)dirtyRect
{
    if (self.fTorrentTableView)
    {
        Torrent* torrent = (Torrent*)self.objectValue;

        // draw progress bar - use cached image when possible
        NSRect barRect = self.fTorrentProgressBarView.frame;

        // Create cache key based on torrent state that affects progress bar appearance
        NSString* cacheKey = [NSString stringWithFormat:@"%@_%f_%d_%d_%f_%f_%d_%f_%d",
                                                        torrent.hashString,
                                                        torrent.progress,
                                                        torrent.active,
                                                        torrent.checking,
                                                        torrent.progressLeft,
                                                        torrent.availableDesired,
                                                        torrent.seeding,
                                                        torrent.progressStopRatio,
                                                        torrent.allDownloaded];

        // Check if we need to regenerate the progress bar image
        if (!self.fCachedProgressBarImage || ![self.fProgressBarCacheKey isEqualToString:cacheKey])
        {
            // Generate new progress bar image
            NSImage* progressImage = [[NSImage alloc] initWithSize:barRect.size];
            [progressImage lockFocus];

            ProgressBarView* progressBar = [[ProgressBarView alloc] init];
            NSRect imageRect = NSMakeRect(0, 0, barRect.size.width, barRect.size.height);
            [progressBar drawBarInRect:imageRect forTableView:self.fTorrentTableView withTorrent:torrent];

            [progressImage unlockFocus];

            self.fCachedProgressBarImage = progressImage;
            self.fProgressBarCacheKey = cacheKey;
        }

        // Draw cached progress bar image
        [self.fCachedProgressBarImage drawInRect:barRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                                        fraction:1.0];

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

    // Update play button colors based on selection
    if (self.fPlayButtonsView)
    {
        BOOL isSelected = (backgroundStyle == NSBackgroundStyleEmphasized);
        NSColor* textColor = isSelected ? NSColor.whiteColor : NSColor.secondaryLabelColor;

        for (NSView* subview in self.fPlayButtonsView.subviews)
        {
            if ([subview isKindOfClass:[PlayButton class]])
            {
                PlayButton* button = (PlayButton*)subview;
                NSString* title = button.title ?: @"";
                NSMutableAttributedString* attrTitle = [[NSMutableAttributedString alloc] initWithString:title];
                [attrTitle addAttribute:NSForegroundColorAttributeName value:textColor range:NSMakeRange(0, title.length)];
                [attrTitle addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:11] range:NSMakeRange(0, title.length)];
                button.attributedTitle = attrTitle;
                if (button.cell)
                {
                    button.cell.backgroundStyle = NSBackgroundStyleNormal;
                }
            }
            else if ([subview isKindOfClass:[NSTextField class]])
            {
                ((NSTextField*)subview).textColor = textColor;
            }
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
