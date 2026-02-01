// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

@class Torrent;

/// Builds play button state and layout for a torrent's content buttons (video/audio/books, seasons).
@interface PlayButtonStateBuilder : NSObject

/// Returns @{ @"snapshot": NSArray, @"playableFiles": NSArray } or nil if no playable files.
+ (NSDictionary*)buildSnapshotForTorrent:(Torrent*)torrent;

/// Pure function: computes state and layout from snapshot; safe on background queue.
+ (NSDictionary*)stateAndLayoutFromSnapshot:(NSArray<NSDictionary*>*)snapshot;

/// Fills iinaUnwatched on video/adult entries in state. Call on main before applying state to UI.
+ (void)enrichStateWithIinaUnwatched:(NSMutableArray<NSMutableDictionary*>*)state forTorrent:(Torrent*)torrent;

/// Returns cached or newly built state; updates torrent's cachedPlayButton*.
+ (NSMutableArray<NSMutableDictionary*>*)stateForTorrent:(Torrent*)torrent;

/// Returns cached or newly built layout for the given state.
+ (NSArray<NSDictionary*>*)layoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state;

@end
