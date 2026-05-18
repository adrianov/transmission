// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import <AVFoundation/AVFoundation.h>

#import "Torrent.h"
#import "VideoDurationHelper.h"

#pragma mark - EBML Constants

enum : uint32_t {
    EbmlId_EBML = 0x1A45DFA3,
    EbmlId_Segment = 0x18538067,
    EbmlId_Info = 0x1549A966,
    EbmlId_TimecodeScale = 0x2AD7B1,
    EbmlId_Duration = 0x4489,
    EbmlId_Cluster = 0x1F43B675,
};

#pragma mark - EBML Low-Level Readers

static uint8_t ebmlVintLength(uint8_t firstByte)
{
    if ((firstByte & 0x80) != 0)
        return 1;
    if ((firstByte & 0x40) != 0)
        return 2;
    if ((firstByte & 0x20) != 0)
        return 3;
    if ((firstByte & 0x10) != 0)
        return 4;
    if ((firstByte & 0x08) != 0)
        return 5;
    if ((firstByte & 0x04) != 0)
        return 6;
    if ((firstByte & 0x02) != 0)
        return 7;
    if ((firstByte & 0x01) != 0)
        return 8;
    return 0;
}

static bool ebmlReadBytes(NSFileHandle* fh, void* buf, NSUInteger len)
{
    NSData* d = [fh readDataOfLength:len];
    if (d.length != len)
        return false;
    memcpy(buf, d.bytes, len);
    return true;
}

static uint64_t ebmlReadVint(NSFileHandle* fh, bool* outUnknown)
{
    if (outUnknown)
        *outUnknown = false;
    uint8_t first;
    if (!ebmlReadBytes(fh, &first, 1))
        return 0;
    uint8_t len = ebmlVintLength(first);
    if (len == 0)
        return 0;
    uint64_t val = first & (uint8_t)(0xFF >> len);
    for (uint8_t i = 1; i < len; i++)
    {
        uint8_t b;
        if (!ebmlReadBytes(fh, &b, 1))
            return 0;
        val = (val << 8) | b;
    }
    if (outUnknown != nil)
    {
        bool allDataBitsSet = true;
        for (uint8_t i = 0; i < len - 1; i++)
        {
            if (((val >> (8 * i)) & 0xFF) != 0xFF)
            {
                allDataBitsSet = false;
                break;
            }
        }
        uint8_t mask = (uint8_t)(0xFF >> len);
        if ((first & mask) == mask && allDataBitsSet)
            *outUnknown = true;
    }
    return val;
}

static uint32_t ebmlReadElementId(NSFileHandle* fh)
{
    uint8_t first;
    if (!ebmlReadBytes(fh, &first, 1))
        return 0;
    uint8_t len = ebmlVintLength(first);
    if (len == 0)
        return 0;
    uint32_t id = first;
    for (uint8_t i = 1; i < len; i++)
    {
        uint8_t b;
        if (!ebmlReadBytes(fh, &b, 1))
            return 0;
        id = (id << 8) | b;
    }
    return id;
}

static uint64_t ebmlReadUint(NSFileHandle* fh, uint64_t size)
{
    if (size == 0 || size > 8)
        return 0;
    uint64_t val = 0;
    for (uint64_t i = 0; i < size; i++)
    {
        uint8_t b;
        if (!ebmlReadBytes(fh, &b, 1))
            return 0;
        val = (val << 8) | b;
    }
    return val;
}

static double ebmlReadFloat(NSFileHandle* fh, uint64_t size)
{
    if (size == 4)
    {
        float f;
        if (!ebmlReadBytes(fh, &f, 4))
            return 0;
        return (double)f;
    }
    if (size == 8)
    {
        double d;
        if (!ebmlReadBytes(fh, &d, 8))
            return 0;
        return d;
    }
    return 0;
}

#pragma mark - MKV Duration

static NSTimeInterval mkvDurationAtPath(NSString* path)
{
    if (!path || path.length == 0)
        return 0;
    NSString* ext = path.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"mkv"] && ![ext isEqualToString:@"webm"] && ![ext isEqualToString:@"mka"])
        return 0;
    NSFileHandle* fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh)
        return 0;
    NSTimeInterval result = 0;
    @try
    {
        uint32_t id = ebmlReadElementId(fh);
        if (id != EbmlId_EBML)
            return 0;
        bool unknownSize = false;
        uint64_t ebmlSize = ebmlReadVint(fh, &unknownSize);
        if (ebmlSize == 0 && !unknownSize)
            return 0;
        if (!unknownSize)
            [fh seekToFileOffset:[fh offsetInFile] + ebmlSize];
        uint64_t const scanLimit = 4 * 1024 * 1024;
        while ([fh offsetInFile] < scanLimit)
        {
            uint32_t segId = ebmlReadElementId(fh);
            if (segId == 0)
                break;
            bool segUnknown = false;
            uint64_t segSize = ebmlReadVint(fh, &segUnknown);
            if (segId == EbmlId_Info)
            {
                uint64_t infoEnd = segUnknown ? scanLimit : [fh offsetInFile] + segSize;
                double timecodeScale = 1000000.0;
                double durationTicks = 0;
                while ([fh offsetInFile] < infoEnd && [fh offsetInFile] < scanLimit)
                {
                    uint32_t subId = ebmlReadElementId(fh);
                    if (subId == 0)
                        break;
                    uint64_t subSize = ebmlReadVint(fh, nil);
                    if (subId == EbmlId_TimecodeScale && subSize > 0 && subSize <= 8)
                        timecodeScale = (double)ebmlReadUint(fh, subSize);
                    else if (subId == EbmlId_Duration && (subSize == 4 || subSize == 8))
                        durationTicks = ebmlReadFloat(fh, subSize);
                    else if (subSize > 0)
                        [fh seekToFileOffset:[fh offsetInFile] + subSize];
                }
                if (durationTicks > 0 && isfinite(durationTicks))
                    result = durationTicks * timecodeScale / 1000000000.0;
                break;
            }
            if (segId == EbmlId_Cluster)
                break;
            if (!segUnknown && segSize > 0 && segSize < scanLimit)
                [fh seekToFileOffset:[fh offsetInFile] + segSize];
            else
                break;
        }
    }
    @finally
    {
        [fh closeFile];
    }
    return result > 0 && isfinite(result) ? result : 0;
}

#pragma mark - Cached Duration (AVFoundation + MKV fallback)

NSTimeInterval videoDurationForPath(NSString* path)
{
    if (!path || path.length == 0)
        return 0;
    static NSCache<NSString*, NSNumber*>* sDurationCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sDurationCache = [[NSCache alloc] init];
        sDurationCache.countLimit = 200;
    });
    NSNumber* cached = [sDurationCache objectForKey:path];
    if (cached != nil)
        return cached.doubleValue;
    NSURL* url = [NSURL fileURLWithPath:path];
    NSTimeInterval sec = 0;
    if (url)
    {
        AVURLAsset* asset = [AVURLAsset assetWithURL:url];
        CMTime cm = asset.duration;
        if (CMTIME_IS_NUMERIC(cm))
            sec = CMTimeGetSeconds(cm);
    }
    if (sec <= 0 || !isfinite(sec))
        sec = mkvDurationAtPath(path);
    if (sec <= 0 || !isfinite(sec))
    {
        [sDurationCache setObject:@(0) forKey:path];
        return 0;
    }
    [sDurationCache setObject:@(sec) forKey:path];
    return sec;
}

#pragma mark - Video Display Decision

BOOL videoDisplayAllowedForItem(Torrent* torrent, NSDictionary* entry, CGFloat progress, BOOL visible)
{
    if (progress >= 1.0)
        return YES;
    if (![Torrent isVideoFileExtension:[torrent pathExtensionOfPlayableItem:entry]])
        return visible;
    NSNumber* indexNum = entry[@"index"];
    if (indexNum == nil)
        return visible;
    NSString* pathOnDisk = [torrent pathToOpenForPlayableItemIfExists:entry];
    if (!pathOnDisk)
        return NO;
    NSTimeInterval durationSec = videoDurationForPath(pathOnDisk);
    if (durationSec <= 0)
        return visible;
    uint64_t fileSize = [torrent fileSizeForIndex:indexNum.unsignedIntegerValue];
    if (fileSize == 0)
        return YES;
    double remainingBytes = (1.0 - progress) * (double)fileSize;
    CGFloat speedKBps = [torrent downloadRate];
    if (speedKBps <= 0)
        return NO;
    double speedBytesPerSec = (double)speedKBps * 1024.0;
    double etaSec = remainingBytes / speedBytesPerSec;
    return etaSec < durationSec;
}
