// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

extern NSString* const kIINAWatchCacheDidUpdateNotification;

/// IINA watch_later integration: determines if a video path is "unwatched" (played < 90%).
/// Uses MD5(path) -> ~/Library/Application Support/com.colliderli.iina/watch_later/<hash>.
@interface IINAWatchHelper : NSObject

/// Returns YES if video at path is unwatched (no watch_later file or start/duration < 0.9).
/// May return YES initially and post kIINAWatchCacheDidUpdateNotification when async duration load completes.
+ (BOOL)unwatchedForVideoPath:(NSString*)path completionObject:(id)completionObject;

/// Clears cached result for path (call after user plays file so next check reflects IINA state).
+ (void)invalidateCacheForPath:(NSString*)path;

@end
