// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>

#import "IINAWatchHelper.h"

static NSMutableDictionary<NSString*, NSNumber*>* sIINAUnwatchedCache;
static dispatch_once_t sIINAUnwatchedCacheOnce;

static NSString* iinaWatchLaterDir(void)
{
    NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0)
        return nil;
    return [dirs.firstObject stringByAppendingPathComponent:@"com.colliderli.iina/watch_later"];
}

/// Normalize path so MD5 matches IINA/mpv watch_later key (they hash the path when opening).
static NSString* normalizedPathForIINALookup(NSString* path)
{
    if (!path || path.length == 0)
        return nil;
    NSString* s = [path stringByStandardizingPath];
    return s.length > 0 ? s : path;
}

static NSString* md5HexForPath(NSString* path)
{
    NSData* data = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length == 0)
        return nil;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
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
    NSString* key = normalizedPathForIINALookup(path);
    if (!key)
        key = path;
    NSNumber* cached = sIINAUnwatchedCache[key];
    if (cached != nil)
        return cached.boolValue;
    NSString* dir = iinaWatchLaterDir();
    NSString* hash = md5HexForPath(key);
    if (!dir || !hash)
    {
        sIINAUnwatchedCache[key] = @YES;
        return YES;
    }
    NSString* watchFile = [dir stringByAppendingPathComponent:hash];
    if (![NSFileManager.defaultManager fileExistsAtPath:watchFile])
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
    sIINAUnwatchedCache[key] = @YES;
    __weak id weakObj = completionObject;
    NSString* pathForDuration = [path copy];
    NSString* keyCopy = [key copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSTimeInterval duration = durationForVideoPath(pathForDuration);
        BOOL unwatched = YES;
        if (duration > 0)
            unwatched = (start / duration) < 0.9;
        dispatch_async(dispatch_get_main_queue(), ^{
            sIINAUnwatchedCache[keyCopy] = @(unwatched);
            [NSNotificationCenter.defaultCenter postNotificationName:kIINAWatchCacheDidUpdateNotification object:weakObj];
        });
    });
    return YES;
}

+ (void)invalidateCacheForPath:(NSString*)path
{
    if (!path)
        return;
    dispatch_once(&sIINAUnwatchedCacheOnce, ^{
        sIINAUnwatchedCache = [NSMutableDictionary dictionary];
    });
    NSString* key = normalizedPathForIINALookup(path);
    [sIINAUnwatchedCache removeObjectForKey:key ?: path];
}

@end
