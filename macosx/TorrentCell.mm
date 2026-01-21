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

- (void)drawRect:(NSRect)dirtyRect
{
    if (self.fTorrentTableView)
    {
        Torrent* torrent = (Torrent*)self.objectValue;

        // draw progress bar
        NSRect barRect = self.fTorrentProgressBarView.frame;
        ProgressBarView* progressBar = [[ProgressBarView alloc] init];
        [progressBar drawBarInRect:barRect forTableView:self.fTorrentTableView withTorrent:torrent];

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

@end
