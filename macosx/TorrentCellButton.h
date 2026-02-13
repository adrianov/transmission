// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

/// Base class for torrent cell buttons (Action, Control, Reveal, URL).
/// Centralizes layer-backed setup, hover event delegation to TorrentTableView,
/// and optional image caching by string key.

#import <Cocoa/Cocoa.h>

@class TorrentCell;
@class TorrentTableView;

@interface TorrentCellButton : NSButton

@property(nonatomic) IBOutlet TorrentCell* torrentCell;
@property(nonatomic, readonly) TorrentTableView* torrentTableView;

/// Current image key for state-based image switching (e.g. @"RevealOff").
/// Subclasses that use image caching should set this and call updateImage.
@property(nonatomic, copy) NSString* imageKey;

/// Registers image names to cache. Call from subclass +initialize.
/// Keys are the full image names (e.g. @"RevealOff", @"RevealHover").
+ (void)setCachedImages:(NSDictionary<NSString*, NSImage*>*)images;

/// Looks up current imageKey in the cache and sets self.image.
- (void)updateImage;

/// Sets imageKey to defaultImageKey and calls updateImage.
- (void)resetImage;

/// Override in subclass to return the default image key (e.g. @"RevealOff"). Default returns nil.
+ (NSString*)defaultImageKey;

@end
