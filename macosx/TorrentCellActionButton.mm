// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellActionButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@implementation TorrentCellActionButton

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self.cell setHighlightsBy:NSNoCellMask];
    self.image = [NSImage imageNamed:@"ActionHover"];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self.torrentTableView];
    [super mouseDown:event];

    BOOL minimal = [NSUserDefaults.standardUserDefaults boolForKey:@"SmallView"];
    if (!minimal)
        [self.torrentTableView hoverEventEndedForView:self];
}

@end
