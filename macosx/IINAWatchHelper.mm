// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "IINAWatchHelper.h"

static NSMutableDictionary<NSString*, NSNumber*>* sIINAUnwatchedCache;
static dispatch_once_t sIINAUnwatchedCacheOnce;

/// ~/Library/Application Support/com.colliderli.iina/watch_later — Transmission must have read access for unwatched state.
static NSString* iinaWatchLaterDir(void)
{
    NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0)
        return nil;
    return [dirs.firstObject stringByAppendingPathComponent:@"com.colliderli.iina/watch_later"];
}

/// Normalize to absolute path and standardize; optionally resolve symlinks if file exists.
static NSString* normalizedPathForIINALookup(NSString* path, BOOL resolveSymlinks)
{
    if (!path || path.length == 0)
        return nil;
    NSString* absolutePath = [path stringByExpandingTildeInPath];
    if (![absolutePath isAbsolutePath])
    {
        NSString* currentDir = [NSFileManager.defaultManager currentDirectoryPath];
        absolutePath = [currentDir stringByAppendingPathComponent:absolutePath];
    }
    NSString* standardized = [absolutePath stringByStandardizingPath];
    if (standardized.length == 0)
        standardized = absolutePath;
    if (resolveSymlinks && [NSFileManager.defaultManager fileExistsAtPath:standardized])
    {
        NSString* resolved = [standardized stringByResolvingSymlinksInPath];
        if (resolved && resolved.length > 0)
            standardized = resolved;
    }
    return standardized;
}

/// Fills UPPERCASE and lowercase MD5 hex of path (UTF-8). Formula: UPPERCASE( MD5( UTF8( PATH ) ) ); IINA uses uppercase.
static void md5HexForPath(NSString* path, NSMutableString* uppercaseHex, NSMutableString* lowercaseHex)
{
    NSData* data = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length == 0)
        return;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
    {
        [uppercaseHex appendFormat:@"%02X", digest[i]];
        [lowercaseHex appendFormat:@"%02x", digest[i]];
    }
}

/// Returns path to watch_later file if it exists. IINA uses uppercase MD5 filenames; we check uppercase first, then lowercase for case-sensitive volumes.
static NSString* existingWatchLaterPath(NSString* dir, NSString* pathKey)
{
    if (!pathKey || pathKey.length == 0)
        return nil;
    NSMutableString* upper = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    NSMutableString* lower = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    md5HexForPath(pathKey, upper, lower);
    if (upper.length == 0)
        return nil;
    NSString* pathUpper = [dir stringByAppendingPathComponent:upper];
    if ([NSFileManager.defaultManager fileExistsAtPath:pathUpper])
        return pathUpper;
    NSString* pathLower = [dir stringByAppendingPathComponent:lower];
    if ([NSFileManager.defaultManager fileExistsAtPath:pathLower])
        return pathLower;
    return nil;
}

static double parseIINAStartFromFile(NSString* filePath)
{
    NSString* content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
    if (!content)
        return -1;
    NSRange startRange = [content rangeOfString:@"start="];
    if (startRange.location == NSNotFound)
        return -1;
    NSUInteger from = startRange.location + startRange.length;
    NSScanner* scanner = [NSScanner scannerWithString:[content substringFromIndex:from]];
    double start = 0;
    if (![scanner scanDouble:&start])
        return -1;
    return start >= 0 ? start : -1;
}

static NSTimeInterval durationForVideoPath(NSString* path)
{
    NSURL* url = [NSURL fileURLWithPath:path];
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
    __block NSTimeInterval duration = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[ @"duration" ] completionHandler:^{
        NSError* err = nil;
        if ([asset statusOfValueForKey:@"duration" error:&err] == AVKeyValueStatusLoaded)
        {
            CMTime t = asset.duration;
            if (CMTIME_IS_NUMERIC(t))
                duration = CMTimeGetSeconds(t);
        }
        dispatch_semaphore_signal(sem);
    }];
    long result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
    (void)result;
    return duration > 0 ? duration : 0;
}

NSString* const kIINAWatchCacheDidUpdateNotification = @"IINAWatchCacheDidUpdate";

@implementation IINAWatchHelper

+ (BOOL)unwatchedForVideoPath:(NSString*)path completionObject:(id)completionObject
{
    if (!path || path.length == 0)
        return YES;
    dispatch_once(&sIINAUnwatchedCacheOnce, ^{
        sIINAUnwatchedCache = [NSMutableDictionary dictionary];
    });
    NSString* key = normalizedPathForIINALookup(path, YES);
    if (!key)
        key = path;
    NSNumber* cached = sIINAUnwatchedCache[key];
    if (cached != nil)
        return cached.boolValue;
    NSString* dir = iinaWatchLaterDir();
    if (!dir)
    {
        sIINAUnwatchedCache[key] = @YES;
        return YES;
    }
    NSString* watchFile = existingWatchLaterPath(dir, key);
    if (!watchFile)
    {
        NSString* keyNoResolve = normalizedPathForIINALookup(path, NO);
        if (keyNoResolve && keyNoResolve != key)
            watchFile = existingWatchLaterPath(dir, keyNoResolve);
    }
    if (!watchFile)
    {
        sIINAUnwatchedCache[key] = @YES;
        return YES;
    }
    double start = parseIINAStartFromFile(watchFile);
    if (start < 0)
    {
        sIINAUnwatchedCache[key] = @YES;
        return YES;
    }
    // Assume watched until async confirms start/duration; avoids showing unwatched for watched files.
    sIINAUnwatchedCache[key] = @NO;
    __weak id weakObj = completionObject;
    NSString* pathForDuration = [path copy];
    NSString* keyCopy = [key copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSTimeInterval duration = durationForVideoPath(pathForDuration);
        // When duration unknown (path unreadable, timeout, unsupported), show unwatched (green) instead of incorrectly gray.
        BOOL unwatched = (duration <= 0) ? YES : ((start / duration) < 0.9);
        dispatch_async(dispatch_get_main_queue(), ^{
            sIINAUnwatchedCache[keyCopy] = @(unwatched);
            [NSNotificationCenter.defaultCenter postNotificationName:kIINAWatchCacheDidUpdateNotification object:weakObj];
        });
    });
    return NO;
}

+ (void)invalidateCacheForPath:(NSString*)path
{
    if (!path)
        return;
    dispatch_once(&sIINAUnwatchedCacheOnce, ^{
        sIINAUnwatchedCache = [NSMutableDictionary dictionary];
    });
    NSString* key = normalizedPathForIINALookup(path, YES);
    [sIINAUnwatchedCache removeObjectForKey:key ?: path];
    NSString* keyNoResolve = normalizedPathForIINALookup(path, NO);
    if (keyNoResolve && ![keyNoResolve isEqualToString:key])
        [sIINAUnwatchedCache removeObjectForKey:keyNoResolve];
}

+ (NSString*)watchLaterBasenameForPath:(NSString*)path resolveSymlinks:(BOOL)resolveSymlinks
{
    NSString* key = normalizedPathForIINALookup(path, resolveSymlinks);
    if (!key || key.length == 0)
        return nil;
    NSMutableString* upper = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    NSMutableString* lower = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    md5HexForPath(key, upper, lower);
    return upper.length > 0 ? upper : nil;
}

@end
