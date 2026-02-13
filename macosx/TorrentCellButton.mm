// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

/// Base class for torrent cell buttons. Centralizes:
/// - Layer-backed rendering setup (wantsLayer, redraw policy)
/// - Hover event delegation to TorrentTableView
/// - Image caching by string key (optional, for state-based buttons)

#import "TorrentCellButton.h"
#import "TorrentCell.h"
#import "TorrentTableView.h"

#import <objc/runtime.h>

static char const kImageCacheKey = '\0';

@implementation TorrentCellButton

- (TorrentTableView*)torrentTableView
{
    return self.torrentCell.fTorrentTableView;
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
}

- (void)mouseEntered:(NSEvent*)event
{
    [super mouseEntered:event];
    [self.torrentTableView hoverEventBeganForView:self];
}

- (void)mouseExited:(NSEvent*)event
{
    [super mouseExited:event];
    [self.torrentTableView hoverEventEndedForView:self];
}

// NSTrackingInVisibleRect tracking areas auto-update; no need to recreate in updateTrackingAreas.

#pragma mark - Image caching

+ (void)setCachedImages:(NSDictionary<NSString*, NSImage*>*)images
{
    objc_setAssociatedObject(self, &kImageCacheKey, images, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (NSDictionary<NSString*, NSImage*>*)cachedImages
{
    return objc_getAssociatedObject(self, &kImageCacheKey);
}

+ (NSString*)defaultImageKey
{
    return nil;
}

- (void)updateImage
{
    NSDictionary* cache = [[self class] cachedImages];
    if (cache && self.imageKey)
        self.image = cache[self.imageKey];
}

- (void)resetImage
{
    self.imageKey = [[self class] defaultImageKey];
    [self updateImage];
}

@end
