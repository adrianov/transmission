// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

@class Torrent;

/// Builds play button state and layout for a torrent's content buttons (video/audio/books, seasons).
@interface PlayButtonStateBuilder : NSObject

/// Asynchronously fills iinaUnwatched for video (by extension) entries using IINA cache checks off main thread.
+ (void)enrichStateWithIinaUnwatched:(NSMutableArray<NSMutableDictionary*>*)state forTorrent:(Torrent*)torrent;

/// Returns cached or newly built state; updates torrent's cachedPlayButton*.
+ (NSMutableArray<NSMutableDictionary*>*)stateForTorrent:(Torrent*)torrent;

/// Returns cached or newly built layout for the given state.
+ (NSArray<NSDictionary*>*)layoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state;

@end
