// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCellControlButton.h"
#import "TorrentTableView.h"
#import "Torrent.h"
#import "TorrentCell.h"

@interface TorrentCellControlButton ()
@property(nonatomic, copy) NSString* controlImageSuffix;
@end

@implementation TorrentCellControlButton

/// Cached control button images. Pre-loaded to avoid string concatenation per draw call.
static NSDictionary<NSString*, NSImage*>* sControlImages;

+ (void)initialize
{
    if (self == [TorrentCellControlButton class])
    {
        NSMutableDictionary* cache = [NSMutableDictionary dictionaryWithCapacity:9];
        for (NSString* prefix in @[ @"Pause", @"Resume", @"ResumeNoWait" ])
            for (NSString* suffix in @[ @"Off", @"Hover", @"On" ])
                cache[[prefix stringByAppendingString:suffix]] = [NSImage imageNamed:[prefix stringByAppendingString:suffix]];
        sControlImages = [cache copy];
    }
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    self.controlImageSuffix = @"Off";
    [self updateImage];
}

- (void)resetImage
{
    self.controlImageSuffix = @"Off";
    [self updateImage];
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    self.controlImageSuffix = @"Hover";
    [self updateImage];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    self.controlImageSuffix = @"Off";
    [self updateImage];
}

- (void)mouseDown:(NSEvent*)event
{
    [self.window makeFirstResponder:self.torrentTableView];
    [super mouseDown:event];
    self.controlImageSuffix = @"On";
    [self updateImage];
    [self.torrentTableView hoverEventEndedForView:self];
}

- (void)updateImage
{
    Torrent* torrent = [self.torrentTableView itemAtRow:[self.torrentTableView rowForView:self]];
    NSString* prefix;
    if (torrent.active)
        prefix = @"Pause";
    else if (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption)
        prefix = @"ResumeNoWait";
    else if (torrent.waitingToStart)
        prefix = @"Pause";
    else
        prefix = @"Resume";
    NSImage* controlImage = sControlImages[[prefix stringByAppendingString:self.controlImageSuffix]];
    self.image = controlImage;
}

@end
