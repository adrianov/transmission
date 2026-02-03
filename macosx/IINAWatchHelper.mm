// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

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

/// ~/Library/Application Support/com.colliderli.iina/history.plist — IINA playback history (NSKeyedArchiver; keys IINAPHUrl, IINAPHMpvmd5).
static NSString* iinaPlaybackHistoryPath(void)
{
    NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0)
        return nil;
    return [dirs.firstObject stringByAppendingPathComponent:@"com.colliderli.iina/history.plist"];
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

/// Resolves NSKeyedArchiver reference: if obj is a dict with CF$UID, returns objects[uid]; else returns obj.
static id resolveKeyedArchiveRef(NSArray* objects, id obj)
{
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0)
        return obj;
    NSDictionary* ref = [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary*)obj : nil;
    NSNumber* uid = ref ? ref[@"CF$UID"] : nil;
    if (!uid)
        return obj;
    NSInteger i = uid.integerValue;
    if (i < 0 || (NSUInteger)i >= objects.count)
        return obj;
    return objects[i];
}

/// Extracts filesystem path from archived URL (raw plist: NSURL is stored as dict with NS.relative / NS.base, or as string).
static NSString* pathFromArchivedURL(id urlObj, NSArray* objects)
{
    if ([urlObj isKindOfClass:[NSURL class]])
        return [(NSURL*)urlObj path];
    if ([urlObj isKindOfClass:[NSString class]])
    {
        NSString* s = (NSString*)urlObj;
        if ([s hasPrefix:@"file://"])
            return [s substringFromIndex:7];
        return s;
    }
    if (![urlObj isKindOfClass:[NSDictionary class]])
        return nil;
    NSDictionary* d = (NSDictionary*)urlObj;
    id relRef = d[@"NS.relative"];
    NSString* relative = nil;
    if ([relRef isKindOfClass:[NSString class]])
        relative = (NSString*)relRef;
    else if (relRef != nil)
    {
        id resolved = resolveKeyedArchiveRef(objects, relRef);
        relative = [resolved isKindOfClass:[NSString class]] ? (NSString*)resolved : nil;
    }
    if (relative.length == 0)
        return nil;
    if ([relative hasPrefix:@"file://"])
        relative = [relative substringFromIndex:7];
    if ([relative hasPrefix:@"/"])
        return relative;
    id baseRef = d[@"NS.base"];
    if (baseRef == nil || baseRef == [NSNull null])
        return relative.length > 0 ? relative : nil;
    id baseObj = resolveKeyedArchiveRef(objects, baseRef);
    NSString* basePath = pathFromArchivedURL(baseObj, objects);
    if (basePath.length == 0)
        return relative;
    return [basePath stringByAppendingPathComponent:relative];
}

static BOOL pathsMatchForHistory(NSString* entryNorm, NSString* pathKey, NSString* pathKeyUnresolved)
{
    if (entryNorm.length == 0)
        return NO;
    if ([entryNorm isEqualToString:pathKey] || (pathKeyUnresolved.length > 0 && [entryNorm isEqualToString:pathKeyUnresolved]))
        return YES;
    if ([entryNorm compare:pathKey options:NSCaseInsensitiveSearch] == NSOrderedSame)
        return YES;
    if (pathKeyUnresolved.length > 0 && [entryNorm compare:pathKeyUnresolved options:NSCaseInsensitiveSearch] == NSOrderedSame)
        return YES;
    NSString* entryLast = entryNorm.lastPathComponent;
    if (entryLast.length > 0 && [entryLast isEqualToString:pathKey.lastPathComponent])
    {
        NSString* pathKeyWithSep = [pathKey stringByAppendingString:@"/"];
        NSString* entryWithSep = [entryNorm stringByAppendingString:@"/"];
        if ([entryWithSep hasSuffix:pathKeyWithSep] || [pathKeyWithSep hasSuffix:entryWithSep])
            return YES;
    }
    return NO;
}

/// Returns YES if path appears in IINA playback history (history.plist). Uses IINAPHMpvmd5 (MD5 of path) and IINAPHUrl; same MD5 formula as watch_later.
static BOOL pathInIINAPlaybackHistory(NSString* pathKey, NSString* pathKeyUnresolved)
{
    if (!pathKey || pathKey.length == 0)
        return NO;
    NSString* historyPath = iinaPlaybackHistoryPath();
    if (!historyPath || ![NSFileManager.defaultManager fileExistsAtPath:historyPath])
        return NO;
    NSDictionary* root = [NSDictionary dictionaryWithContentsOfFile:historyPath];
    if (!root)
        return NO;
    NSArray* objects = root[@"$objects"];
    NSDictionary* top = root[@"$top"];
    if (![objects isKindOfClass:[NSArray class]] || objects.count == 0 || ![top isKindOfClass:[NSDictionary class]])
        return NO;
    id rootArray = nil;
    id rootRef = top[@"root"];
    if (rootRef != nil)
        rootArray = resolveKeyedArchiveRef(objects, rootRef);
    if (![rootArray isKindOfClass:[NSArray class]])
    {
        for (NSString* key in top)
        {
            id val = resolveKeyedArchiveRef(objects, top[key]);
            if ([val isKindOfClass:[NSArray class]])
            {
                rootArray = val;
                break;
            }
        }
    }
    if (![rootArray isKindOfClass:[NSArray class]])
        return NO;
    NSMutableString* pathKeyUpper = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    NSMutableString* pathKeyLower = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    md5HexForPath(pathKey, pathKeyUpper, pathKeyLower);
    for (id itemRef in (NSArray*)rootArray)
    {
        id entry = resolveKeyedArchiveRef(objects, itemRef);
        if (![entry isKindOfClass:[NSDictionary class]])
            continue;
        NSDictionary* entryDict = (NSDictionary*)entry;
        id md5Ref = entryDict[@"IINAPHMpvmd5"];
        if (md5Ref)
        {
            id md5Obj = resolveKeyedArchiveRef(objects, md5Ref);
            if ([md5Obj isKindOfClass:[NSString class]])
            {
                NSString* entryMd5 = (NSString*)md5Obj;
                if (entryMd5.length > 0 && ([entryMd5 isEqualToString:pathKeyUpper] || [entryMd5 isEqualToString:pathKeyLower]))
                    return YES;
            }
        }
        id urlRef = entryDict[@"IINAPHUrl"];
        if (urlRef)
        {
            id urlObj = resolveKeyedArchiveRef(objects, urlRef);
            NSString* entryPath = pathFromArchivedURL(urlObj, objects);
            if (entryPath.length > 0)
            {
                NSString* entryNorm = normalizedPathForIINALookup(entryPath, YES);
                if (entryNorm.length == 0)
                    entryNorm = normalizedPathForIINALookup(entryPath, NO);
                if (entryNorm.length > 0 && pathsMatchForHistory(entryNorm, pathKey, pathKeyUnresolved ?: @""))
                    return YES;
            }
        }
    }
    return NO;
}

NSString* const kIINAWatchCacheDidUpdateNotification = @"IINAWatchCacheDidUpdate";

@implementation IINAWatchHelper

+ (BOOL)unwatchedForVideoPath:(NSString*)path completionObject:(id)completionObject
{
    (void)completionObject;
    if (!path || path.length == 0)
        return NO;
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
        sIINAUnwatchedCache[key] = @NO;
        return NO;
    }
    NSString* watchFile = existingWatchLaterPath(dir, key);
    NSString* keyNoResolve = nil;
    if (!watchFile)
    {
        keyNoResolve = normalizedPathForIINALookup(path, NO);
        if (keyNoResolve && keyNoResolve != key)
            watchFile = existingWatchLaterPath(dir, keyNoResolve);
    }
    // When playback finishes IINA may remove the watch_later file; treat as watched if path is in IINA playback history.
    BOOL unwatched = (watchFile == nil) && !pathInIINAPlaybackHistory(key, keyNoResolve ?: @"");
    sIINAUnwatchedCache[key] = @(unwatched);
    return unwatched;
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
