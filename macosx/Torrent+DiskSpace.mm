// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "Torrent.h"
#import "TorrentPrivate.h"

static NSTimeInterval const kDiskSpaceCheckThrottleSeconds = 5.0;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (DiskSpace)

- (BOOL)alertForRemainingDiskSpace
{
    return [self alertForRemainingDiskSpaceBypassThrottle:NO];
}

- (BOOL)alertForRemainingDiskSpaceBypassThrottle:(BOOL)bypass
{
    if (self.allDownloaded || ![self.fDefaults boolForKey:@"WarningRemainingSpace"])
    {
        self.fPausedForDiskSpace = NO;
        return YES;
    }

    NSString* downloadFolder = self.currentDirectory;
    NSDictionary* systemAttributes;
    if ((systemAttributes = [NSFileManager.defaultManager attributesOfFileSystemForPath:downloadFolder error:NULL]))
    {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!bypass && now - self.fLastDiskSpaceCheckTime <= kDiskSpaceCheckThrottleSeconds)
        {
            return self.fPausedForDiskSpace == NO;
        }
        self.fLastDiskSpaceCheckTime = now;
        uint64_t const remainingSpace = ((NSNumber*)systemAttributes[NSFileSystemFreeSize]).unsignedLongLongValue;
        uint64_t const totalSpace = ((NSNumber*)systemAttributes[NSFileSystemSize]).unsignedLongLongValue;
        NSNumber* volumeID = systemAttributes[NSFileSystemNumber];

        self.fDiskSpaceUsedByTorrents = [self totalTorrentDiskUsageOnVolume:volumeID];
        self.fDiskSpaceAvailable = remainingSpace;
        self.fDiskSpaceTotal = totalSpace;
        uint64_t const totalNeededOnVolume = self.sizeLeft + [self totalTorrentDiskNeededOnVolume:volumeID];
        self.fDiskSpaceNeeded = totalNeededOnVolume;

        if (remainingSpace < totalNeededOnVolume)
        {
            self.fPausedForDiskSpace = YES;
            return NO;
        }
    }
    self.fPausedForDiskSpace = NO;
    return YES;
}

- (NSNumber*)volumeIdentifier
{
    NSDictionary* systemAttributes = [NSFileManager.defaultManager attributesOfFileSystemForPath:self.currentDirectory error:NULL];
    return systemAttributes[NSFileSystemNumber];
}

- (uint64_t)totalTorrentDiskUsage
{
    return [self totalTorrentDiskUsageOnVolume:nil];
}

- (uint64_t)totalTorrentDiskUsageOnVolume:(NSNumber*)volumeID
{
    if (!self.fSession)
        return 0;

    size_t const torrentCount = tr_sessionGetAllTorrents(self.fSession, nullptr, 0);
    if (torrentCount == 0)
        return 0;

    std::vector<tr_torrent*> handles(torrentCount);
    tr_sessionGetAllTorrents(self.fSession, handles.data(), handles.size());

    uint64_t totalUsage = 0;
    for (tr_torrent* h : handles)
    {
        if (volumeID != nil)
        {
            auto const path = @(tr_torrentGetDownloadDir(h));
            NSDictionary* attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:NULL];
            if (![attrs[NSFileSystemNumber] isEqualToNumber:volumeID])
                continue;
        }

        tr_stat const* st = tr_torrentStat(h);
        if (st)
            totalUsage += st->sizeWhenDone;
    }
    return totalUsage;
}

- (uint64_t)totalTorrentDiskNeeded
{
    return [self totalTorrentDiskNeededOnVolume:nil group:-1];
}

- (uint64_t)totalTorrentDiskNeededOnVolume:(NSNumber*)volumeID group:(NSInteger)groupValue
{
    if (!self.fSession)
        return 0;

    size_t const torrentCount = tr_sessionGetAllTorrents(self.fSession, nullptr, 0);
    if (torrentCount == 0)
        return 0;

    std::vector<tr_torrent*> handles(torrentCount);
    tr_sessionGetAllTorrents(self.fSession, handles.data(), handles.size());

    uint64_t totalNeeded = 0;
    for (tr_torrent* h : handles)
    {
        if (volumeID != nil && h == self.fHandle)
            continue;

        if (volumeID != nil)
        {
            auto const path = @(tr_torrentGetDownloadDir(h));
            NSDictionary* attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:NULL];
            if (![attrs[NSFileSystemNumber] isEqualToNumber:volumeID])
                continue;
        }

        tr_stat const* st = tr_torrentStat(h);
        if (st && (st->activity == TR_STATUS_DOWNLOAD || st->activity == TR_STATUS_SEED))
            totalNeeded += st->leftUntilDone;
    }
    return totalNeeded;
}

- (uint64_t)totalTorrentDiskNeededOnVolume:(NSNumber*)volumeID
{
    return [self totalTorrentDiskNeededOnVolume:volumeID group:-1];
}

@end
#pragma clang diagnostic pop
