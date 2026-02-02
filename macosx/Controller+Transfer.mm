// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Transfer control (resume/stop) and disk-space handling. Central place for resume-after-free-space logic.

#import "ControllerPrivate.h"
#import "GroupsController.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentGroup.h"

@implementation Controller (Transfer)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
- (void)resumeTorrents:(NSArray<Torrent*>*)torrents
{
    for (Torrent* torrent in torrents)
    {
        if (torrent.pausedForDiskSpace)
        {
            // Force recheck so resume works after user frees space (avoids stale cache)
            if ([torrent alertForRemainingDiskSpaceBypassThrottle:YES])
                [torrent startTransfer];
            else
                [self handleTorrentPausedForDiskSpace:torrent];
        }
        else
            [torrent startTransfer];
    }

    [self fullUpdateUI];
}

- (void)resumeTorrentsNoWait:(NSArray<Torrent*>*)torrents
{
    for (Torrent* torrent in torrents)
    {
        if (torrent.pausedForDiskSpace)
        {
            // Force recheck so resume works after user frees space (avoids stale cache)
            if ([torrent alertForRemainingDiskSpaceBypassThrottle:YES])
                [torrent startTransferNoQueue];
            else
                [self handleTorrentPausedForDiskSpace:torrent];
        }
        else
            [torrent startTransferNoQueue];
    }

    [self fullUpdateUI];
}

- (void)stopTorrents:(NSArray<Torrent*>*)torrents
{
    for (Torrent* torrent in torrents)
    {
        if (torrent.waitingToStart)
            [torrent stopTransfer];
    }

    for (Torrent* torrent in torrents)
        [torrent stopTransfer];

    [self fullUpdateUI];
}

- (void)invalidateAllGroupCaches
{
    for (TorrentGroup* group in self.fDisplayedTorrents)
    {
        if ([group isKindOfClass:[TorrentGroup class]])
            [group invalidateCache];
    }
}

- (void)handleTorrentPausedForDiskSpace:(Torrent*)torrent
{
    if (torrent.pausedForDiskSpace)
    {
        if ([torrent alertForRemainingDiskSpaceBypassThrottle:YES])
        {
            [torrent startTransfer];
            return;
        }
    }

    if (!torrent.pausedForDiskSpace || torrent.diskSpaceDialogShown)
        return;
    torrent.fDiskSpaceDialogShown = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint64_t const currentFreeSpace = torrent.diskSpaceAvailable;
        NSNumber* const volumeID = torrent.volumeIdentifier;
        NSInteger const groupValue = torrent.groupValue;

        uint64_t const targetSpace = torrent.sizeLeft + [torrent totalTorrentDiskNeededOnVolume:volumeID group:-1];

        if (currentFreeSpace >= targetSpace)
            return;

        uint64_t const deficit = targetSpace - currentFreeSpace;

        NSMutableArray<Torrent*>* candidates = [NSMutableArray array];
        for (Torrent* t in self.fTorrents)
        {
            if (t != torrent && [t.volumeIdentifier isEqualToNumber:volumeID] && t.groupValue == groupValue)
                [candidates addObject:t];
        }
        [candidates sortUsingComparator:^NSComparisonResult(Torrent* a, Torrent* b) {
            NSDate* dateA = [a.dateLastPlayed compare:a.dateAdded] == NSOrderedDescending ? a.dateLastPlayed : a.dateAdded;
            NSDate* dateB = [b.dateLastPlayed compare:b.dateAdded] == NSOrderedDescending ? b.dateLastPlayed : b.dateAdded;
            if (dateA && dateB)
                return [dateA compare:dateB];
            if (dateA)
                return NSOrderedAscending;
            if (dateB)
                return NSOrderedDescending;
            return NSOrderedSame;
        }];

        uint64_t freedPotential = 0;
        NSMutableArray<Torrent*>* toDelete = [NSMutableArray array];
        for (Torrent* t in candidates)
        {
            if (freedPotential >= deficit)
                break;
            freedPotential += t.sizeWhenDone;
            [toDelete addObject:t];
        }

        if (toDelete.count == 0 || freedPotential < deficit)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert* err = [[NSAlert alloc] init];
                err.messageText = NSLocalizedString(@"Not enough disk space", @"auto-delete error title");
                NSString* neededStr = [NSString stringForFileSize:deficit];
                NSString* freedStr = [NSString stringForFileSize:freedPotential];
                NSString* groupName = [GroupsController.groups nameForIndex:groupValue];
                if (toDelete.count == 0)
                    err.informativeText = [NSString
                        stringWithFormat:NSLocalizedString(
                                             @"Need %@ to add this torrent, but no old torrents in group '%@' can be deleted to free space.",
                                             @"auto-delete error size message"),
                                         neededStr,
                                         groupName];
                else
                    err.informativeText = [NSString stringWithFormat:NSLocalizedString(
                                                                         @"Need %@ to add this torrent, but only %@ could be freed from group '%@'.",
                                                                         @"auto-delete error size message"),
                                                                     neededStr,
                                                                     freedStr,
                                                                     groupName];
                [err addButtonWithTitle:NSLocalizedString(@"OK", nil)];
                [err beginSheetModalForWindow:self.fWindow completionHandler:nil];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray<NSString*>* lines = [NSMutableArray array];
            for (Torrent* t in toDelete)
            {
                NSString* sizeStr = [NSString stringForFileSize:t.sizeWhenDone];
                [lines addObject:[NSString stringWithFormat:@"\n  • %@ (%@)", t.displayName, sizeStr]];
            }
            NSString* list = [lines componentsJoinedByString:@""];

            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = NSLocalizedString(@"Low Disk Space", @"auto-delete alert title");
            NSString* deficitStr = [NSString stringForFileSize:deficit];
            NSString* freedStr = [NSString stringForFileSize:freedPotential];
            alert.informativeText = [NSString
                stringWithFormat:NSLocalizedString(
                                     @"Need %@ to add this torrent; will delete these (%@ freed):%@\n\nContinue with deletion?",
                                     @"auto-delete delete confirmation size message"),
                                 deficitStr,
                                 freedStr,
                                 list];

            [alert addButtonWithTitle:NSLocalizedString(@"Delete", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

            [alert beginSheetModalForWindow:self.fWindow completionHandler:^(NSModalResponse response) {
                if (response == NSAlertFirstButtonReturn)
                {
                    torrent.fDiskSpaceDialogShown = NO;
                    [self confirmRemoveTorrents:toDelete deleteData:YES completionHandler:^{
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            if ([torrent alertForRemainingDiskSpaceBypassThrottle:YES])
                                [torrent startTransfer];
                            [torrent update];
                        });
                    }];
                }
            }];
        });
    });
}

- (void)autoDeleteOldTorrentsAtPath:(NSString*)path
                              group:(NSInteger)groupValue
                           forBytes:(uint64_t)bytesNeeded
                         completion:(void (^)(void))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary* systemAttributes = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:NULL];
        if (!systemAttributes)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
            return;
        }

        uint64_t const currentFreeSpace = ((NSNumber*)systemAttributes[NSFileSystemFreeSize]).unsignedLongLongValue;
        NSNumber* const volumeID = systemAttributes[NSFileSystemNumber];

        Torrent* proxy = self.fTorrents.firstObject;
        uint64_t const targetSpace = bytesNeeded + (proxy ? [proxy totalTorrentDiskNeededOnVolume:volumeID group:-1] : 0);

        if (currentFreeSpace >= targetSpace)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
            return;
        }

        uint64_t const deficit = targetSpace - currentFreeSpace;

        NSMutableArray<Torrent*>* candidates = [NSMutableArray array];
        for (Torrent* t in self.fTorrents)
        {
            if ([t.volumeIdentifier isEqualToNumber:volumeID] && t.groupValue == groupValue)
                [candidates addObject:t];
        }
        [candidates sortUsingComparator:^NSComparisonResult(Torrent* a, Torrent* b) {
            NSDate* dateA = [a.dateLastPlayed compare:a.dateAdded] == NSOrderedDescending ? a.dateLastPlayed : a.dateAdded;
            NSDate* dateB = [b.dateLastPlayed compare:b.dateAdded] == NSOrderedDescending ? b.dateLastPlayed : b.dateAdded;
            if (dateA && dateB)
                return [dateA compare:dateB];
            if (dateA)
                return NSOrderedAscending;
            if (dateB)
                return NSOrderedDescending;
            return NSOrderedSame;
        }];

        uint64_t freedPotential = 0;
        NSMutableArray<Torrent*>* toDelete = [NSMutableArray array];
        for (Torrent* t in candidates)
        {
            if (freedPotential >= deficit)
                break;
            freedPotential += t.sizeWhenDone;
            [toDelete addObject:t];
        }

        if (freedPotential < deficit || toDelete.count == 0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert* err = [[NSAlert alloc] init];
                err.messageText = NSLocalizedString(@"Not enough disk space", @"auto-delete error title");
                NSString* neededStr = [NSString stringForFileSize:deficit];
                NSString* freedStr = [NSString stringForFileSize:freedPotential];
                NSString* groupName = [GroupsController.groups nameForIndex:groupValue];
                if (toDelete.count == 0)
                    err.informativeText = [NSString
                        stringWithFormat:NSLocalizedString(
                                             @"Need %@ to add this torrent, but no old torrents in group '%@' can be deleted to free space.",
                                             @"auto-delete error size message"),
                                         neededStr,
                                         groupName];
                else
                    err.informativeText = [NSString stringWithFormat:NSLocalizedString(
                                                                         @"Need %@ to add this torrent, but only %@ could be freed from group '%@'.",
                                                                         @"auto-delete error size message"),
                                                                     neededStr,
                                                                     freedStr,
                                                                     groupName];
                [err addButtonWithTitle:NSLocalizedString(@"OK", nil)];
                [err beginSheetModalForWindow:self.fWindow completionHandler:nil];
            });
            return;
        }

        if (toDelete.count > 0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableArray<NSString*>* lines = [NSMutableArray array];
                for (Torrent* t in toDelete)
                {
                    NSString* sizeStr = [NSString stringForFileSize:t.sizeWhenDone];
                    [lines addObject:[NSString stringWithFormat:@"\n  • %@ (%@)", t.displayName, sizeStr]];
                }
                NSString* list = [lines componentsJoinedByString:@""];
                NSAlert* alert = [[NSAlert alloc] init];
                alert.messageText = NSLocalizedString(@"Low Disk Space", @"auto-delete alert title");
                NSString* deficitStr = [NSString stringForFileSize:deficit];
                NSString* freedStr = [NSString stringForFileSize:freedPotential];
                alert.informativeText = [NSString
                    stringWithFormat:NSLocalizedString(
                                         @"Need %@ to add this torrent; will delete these (%@ freed):%@\n\nContinue with deletion?",
                                         @"auto-delete delete confirmation size message"),
                                     deficitStr,
                                     freedStr,
                                     list];
                [alert addButtonWithTitle:NSLocalizedString(@"Delete", nil)];
                [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
                [alert beginSheetModalForWindow:self.fWindow completionHandler:^(NSModalResponse response) {
                    if (response == NSAlertFirstButtonReturn)
                    {
                        [self removeTorrents:toDelete deleteData:YES];
                        completion();
                    }
                }];
            });
        }
        else
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

#pragma clang diagnostic pop
@end
