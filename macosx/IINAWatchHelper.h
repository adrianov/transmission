// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

extern NSString* const kIINAWatchCacheDidUpdateNotification;

/// IINA watch_later integration: determines if a video path is "unwatched" by checking whether a watch_later file exists.
/// We only check file existence; we do not read or parse watch_later file contents.
/// When IINA removes the watch_later file after playback finishes, we treat the path as watched if it appears in IINA playback history (history.plist in Application Support; NSKeyedArchiver with IINAPHUrl / IINAPHMpvmd5).
/// Formula: WATCH_LATER_FILENAME = UPPERCASE( MD5( UTF8( NORMALIZED_FULL_PATH ) ) ) — 32-char hex.
/// Location: ~/Library/Application Support/com.colliderli.iina/watch_later/<WATCH_LATER_FILENAME>; playback history: same dir, history.plist.
@interface IINAWatchHelper : NSObject

/// Returns YES if video at path is unwatched (no watch_later file and not in IINA playback history). Returns NO if watched (file exists or in history).
+ (BOOL)unwatchedForVideoPath:(NSString*)path completionObject:(id)completionObject;

/// Clears cached result for path (call after user plays file so next check reflects IINA state).
+ (void)invalidateCacheForPath:(NSString*)path;

/// Returns the watch_later filename (32-char uppercase MD5 hex of normalized path) used to search IINA progress file, or nil.
+ (NSString*)watchLaterBasenameForPath:(NSString*)path resolveSymlinks:(BOOL)resolveSymlinks;

@end
