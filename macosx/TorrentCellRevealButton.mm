// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellRevealButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@implementation TorrentCellRevealButton

+ (void)initialize
{
    if (self == [TorrentCellRevealButton class])
    {
        [self setCachedImages:@{
            @"RevealOff" : [NSImage imageNamed:@"RevealOff"],
            @"RevealHover" : [NSImage imageNamed:@"RevealHover"],
            @"RevealOn" : [NSImage imageNamed:@"RevealOn"],
        }];
    }
}

+ (NSString*)defaultImageKey
{
    return @"RevealOff";
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self resetImage];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    self.imageKey = @"RevealHover";
    [self updateImage];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    [self resetImage];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self.torrentTableView];
    [super mouseDown:event];
    self.imageKey = @"RevealOn";
    [self updateImage];
}

@end
