// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

extern NSString* const kIINAWatchCacheDidUpdateNotification;

/// IINA watch_later integration: determines if a video path is "unwatched" (played < 90%).
/// Formula: WATCH_LATER_FILENAME = UPPERCASE( MD5( UTF8( NORMALIZED_FULL_PATH ) ) ) — 32-char hex.
/// Location: ~/Library/Application Support/com.colliderli.iina/watch_later/<WATCH_LATER_FILENAME>.
/// Unwatched state requires read access to that folder; if Transmission cannot read it, videos show as unwatched.
@interface IINAWatchHelper : NSObject

/// Returns YES if video at path is unwatched (no watch_later file or start/duration < 0.9).
/// May return YES initially and post kIINAWatchCacheDidUpdateNotification when async duration load completes.
+ (BOOL)unwatchedForVideoPath:(NSString*)path completionObject:(id)completionObject;

/// Clears cached result for path (call after user plays file so next check reflects IINA state).
+ (void)invalidateCacheForPath:(NSString*)path;

/// Returns the watch_later filename (32-char uppercase MD5 hex of normalized path) used to search IINA progress file, or nil.
+ (NSString*)watchLaterBasenameForPath:(NSString*)path resolveSymlinks:(BOOL)resolveSymlinks;

@end
