// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellURLButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@implementation TorrentCellURLButton

+ (void)initialize
{
    if (self == [TorrentCellURLButton class])
    {
        [self setCachedImages:@{
            @"URLOff" : [NSImage imageNamed:@"URLOff"],
            @"URLHover" : [NSImage imageNamed:@"URLHover"],
            @"URLOn" : [NSImage imageNamed:@"URLOn"],
        }];
    }
}

+ (NSString*)defaultImageKey
{
    return @"URLOff";
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self resetImage];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    self.imageKey = @"URLHover";
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
    self.imageKey = @"URLOn";
    [self updateImage];
}

@end
