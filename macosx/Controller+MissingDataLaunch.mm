// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// On launch: find missing-data torrents, try to recover by switching to a folder where files exist, then remove the rest.

#include <libtransmission/transmission.h>

#import "ControllerPrivate.h"
#import "Torrent.h"

@implementation Controller (MissingDataLaunch)

- (void)removeMissingDataTorrentsOnLaunch
{
    if (self.fTorrents.count == 0)
    {
        return;
    }

    NSArray<Torrent*>* torrents = [self.fTorrents copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [Torrent updateTorrents:torrents];

        NSSet<NSString*>* candidateDirs = [self missingDataCandidateDownloadDirsFromTorrents:torrents];
        NSArray<Torrent*>* toRemove = [self missingDataTorrentsToRemoveFromTorrents:torrents candidateDirs:candidateDirs];

        if (toRemove.count == 0)
        {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            for (Torrent* torrent in toRemove)
            {
                [self.fTorrentHashes removeObjectForKey:torrent.hashString];
            }
            [self confirmRemoveTorrents:toRemove deleteData:NO];
        });
    });
}

- (NSSet<NSString*>*)missingDataCandidateDownloadDirsFromTorrents:(NSArray<Torrent*>*)torrents
{
    NSMutableSet<NSString*>* set = [NSMutableSet set];
    for (Torrent* t in torrents)
    {
        char const* dir = tr_torrentGetDownloadDir(t.torrentStruct);
        if (dir != nullptr && *dir != '\0')
        {
            [set addObject:@(dir)];
        }
    }
    return set;
}

- (BOOL)setTorrentLocationFromCandidatesIfNeeded:(Torrent*)torrent candidateDirs:(NSSet<NSString*>*)candidateDirs didSwitch:(BOOL*)didSwitch
{
    if (didSwitch != NULL)
    {
        *didSwitch = NO;
    }
    NSString* currentDir = torrent.currentDirectory;
    if (currentDir.length == 0)
    {
        return NO;
    }
    if ([torrent allFilesExistAtPath:currentDir])
    {
        return YES;
    }
    for (NSString* candidate in candidateDirs)
    {
        if ([candidate isEqualToString:currentDir])
        {
            continue;
        }
        if ([torrent allFilesExistAtPath:candidate])
        {
            volatile int status = TR_LOC_MOVING;
            tr_torrentSetLocation(torrent.torrentStruct, candidate.UTF8String, NO, (int volatile*)&status);
            while (status == TR_LOC_MOVING)
            {
                usleep(50000);
            }
            if (didSwitch != NULL)
            {
                *didSwitch = YES;
            }
            return YES;
        }
    }
    return NO;
}

- (NSArray<Torrent*>*)missingDataTorrentsToRemoveFromTorrents:(NSArray<Torrent*>*)torrents
             candidateDirs:(NSSet<NSString*>*)candidateDirs
{
    NSMutableArray<Torrent*>* toRemove = [NSMutableArray array];
    for (Torrent* torrent in torrents)
    {
        if (!torrent.error || !torrent.allFilesMissing)
        {
            continue;
        }
        BOOL didSwitch = NO;
        if ([self setTorrentLocationFromCandidatesIfNeeded:torrent candidateDirs:candidateDirs didSwitch:&didSwitch] && didSwitch)
        {
            tr_torrentStart(torrent.torrentStruct);
            continue;
        }
        [toRemove addObject:torrent];
    }
    return toRemove;
}

@end
