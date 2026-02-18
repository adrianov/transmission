// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Remove transfers: confirm sheet, table removal, clear completed. Keeps removal logic out of main Controller.

#import "ControllerPrivate.h"
#import "Badger.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"

@implementation Controller (Remove)

- (void)removeTorrents:(NSArray<Torrent*>*)torrents deleteData:(BOOL)deleteData
{
    if ([self.fDefaults boolForKey:@"CheckRemove"])
    {
        NSUInteger active = 0, downloading = 0;
        for (Torrent* torrent in torrents)
        {
            if (torrent.active)
            {
                ++active;
                if (!torrent.seeding)
                {
                    ++downloading;
                }
            }
        }

        if ([self.fDefaults boolForKey:@"CheckRemoveDownloading"] ? downloading > 0 : active > 0)
        {
            NSString *title, *message;

            NSUInteger const selected = torrents.count;
            if (selected == 1)
            {
                NSString* torrentName = torrents[0].name;

                if (deleteData)
                {
                    title = [NSString stringWithFormat:NSLocalizedString(
                                                           @"Are you sure you want to remove \"%@\" from the transfer list"
                                                            " and permanently delete the data?",
                                                           "Removal confirm panel -> title"),
                                                       torrentName];
                }
                else
                {
                    title = [NSString
                        stringWithFormat:NSLocalizedString(@"Are you sure you want to remove \"%@\" from the transfer list?", "Removal confirm panel -> title"),
                                         torrentName];
                }

                message = NSLocalizedString(
                    @"This transfer is active."
                     " Once removed, continuing the transfer will require the torrent file or magnet link.",
                    "Removal confirm panel -> message");
            }
            else
            {
                if (deleteData)
                {
                    title = [NSString localizedStringWithFormat:NSLocalizedString(
                                                                    @"Are you sure you want to remove %lu transfers from the transfer list"
                                                                     " and permanently delete the data files?",
                                                                    "Removal confirm panel -> title"),
                                                                selected];
                }
                else
                {
                    title = [NSString localizedStringWithFormat:NSLocalizedString(
                                                                    @"Are you sure you want to remove %lu transfers from the transfer list?",
                                                                    "Removal confirm panel -> title"),
                                                                selected];
                }

                if (selected == active)
                {
                    message = [NSString localizedStringWithFormat:NSLocalizedString(@"There are %lu active transfers.", "Removal confirm panel -> message part 1"),
                                                                  active];
                }
                else
                {
                    message = [NSString localizedStringWithFormat:NSLocalizedString(@"There are %1$lu transfers (%2$lu active).", "Removal confirm panel -> message part 1"),
                                                                  selected,
                                                                  active];
                }
                message = [message stringByAppendingFormat:@" %@",
                                                           NSLocalizedString(
                                                               @"Once removed, continuing the transfers will require the torrent files or magnet links.",
                                                               "Removal confirm panel -> message part 2")];
            }

            NSAlert* alert = [[NSAlert alloc] init];
            alert.alertStyle = NSAlertStyleInformational;
            alert.messageText = title;
            alert.informativeText = message;
            [alert addButtonWithTitle:NSLocalizedString(@"Remove", "Removal confirm panel -> button")];
            [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "Removal confirm panel -> button")];

            [alert beginSheetModalForWindow:self.fWindow completionHandler:^(NSModalResponse returnCode) {
                if (returnCode == NSAlertFirstButtonReturn)
                {
                    [self confirmRemoveTorrents:torrents deleteData:deleteData];
                }
            }];
            return;
        }
    }

    [self confirmRemoveTorrents:torrents deleteData:deleteData];
}

- (void)confirmRemoveTorrents:(NSArray<Torrent*>*)torrents deleteData:(BOOL)deleteData
{
    [self confirmRemoveTorrents:torrents deleteData:deleteData completionHandler:nil];
}

- (void)confirmRemoveTorrents:(NSArray<Torrent*>*)torrents
                   deleteData:(BOOL)deleteData
            completionHandler:(void (^)(void))completionHandler
{
    for (Torrent* torrent in torrents)
    {
        if (torrent.waitingToStart)
        {
            [torrent stopTransfer];
        }

        [self.fTableView removeCollapsedGroup:torrent.groupValue];

        [self.fBadger removeTorrent:torrent];
    }

    NSIndexSet* indexesToRemove = [torrents indexesOfObjectsWithOptions:NSEnumerationConcurrent
                                                            passingTest:^BOOL(Torrent* torrent, NSUInteger /*idx*/, BOOL* /*stop*/) {
                                                                return [self.fTorrents indexOfObjectIdenticalTo:torrent] != NSNotFound;
                                                            }];
    if (torrents.count != indexesToRemove.count)
    {
        NSLog(
            @"trying to remove %ld transfers, but %ld have already been removed",
            torrents.count,
            torrents.count - indexesToRemove.count);
        torrents = [torrents objectsAtIndexes:indexesToRemove];

        if (indexesToRemove.count == 0)
        {
            [self fullUpdateUI];
            if (completionHandler != nil)
            {
                completionHandler();
            }
            return;
        }
    }

    [self.fTorrents removeObjectsInArray:torrents];

    for (Torrent* torrent in torrents)
    {
        [self.fTorrentHashes removeObjectForKey:torrent.hashString];
    }

    __block NSUInteger remainingDeletions = torrents.count;
    void (^onDeletionComplete)(void) = ^{
        if (--remainingDeletions == 0)
        {
            if (completionHandler != nil)
            {
                completionHandler();
            }
        }
    };

    __block BOOL beganUpdate = NO;

    void (^doTableRemoval)(NSMutableArray*, id) = ^(NSMutableArray<Torrent*>* displayedTorrents, id parent) {
        NSIndexSet* indexes = [displayedTorrents indexesOfObjectsWithOptions:NSEnumerationConcurrent
                                                                 passingTest:^BOOL(Torrent* obj, NSUInteger /*idx*/, BOOL* /*stop*/) {
                                                                     return [torrents containsObject:obj];
                                                                 }];

        if (indexes.count > 0)
        {
            if (!beganUpdate)
            {
                [NSAnimationContext beginGrouping];

                NSAnimationContext.currentContext.completionHandler = ^{
                    for (Torrent* torrent in torrents)
                    {
                        if (completionHandler != nil)
                        {
                            [torrent closeRemoveTorrent:deleteData completionHandler:^(BOOL succeeded) {
                                (void)succeeded;
                                onDeletionComplete();
                            }];
                        }
                        else
                        {
                            [torrent closeRemoveTorrent:deleteData];
                        }
                    }

                    [self fullUpdateUI];
                    [self applyFilter];
                };

                [self.fTableView beginUpdates];
                beganUpdate = YES;
            }

            [self.fTableView removeItemsAtIndexes:indexes inParent:parent withAnimation:NSTableViewAnimationSlideLeft];

            [displayedTorrents removeObjectsAtIndexes:indexes];
        }
    };

    if (self.fDisplayedTorrents.count > 0)
    {
        if ([self.fDisplayedTorrents[0] isKindOfClass:[TorrentGroup class]])
        {
            for (TorrentGroup* group in self.fDisplayedTorrents)
            {
                doTableRemoval(group.torrents, group);
            }
        }
        else
        {
            doTableRemoval(self.fDisplayedTorrents, nil);
        }

        if (beganUpdate)
        {
            [self.fTableView endUpdates];
            [NSAnimationContext endGrouping];
        }
    }

    if (!beganUpdate)
    {
        for (Torrent* torrent in torrents)
        {
            if (completionHandler != nil)
            {
                [torrent closeRemoveTorrent:deleteData completionHandler:^(BOOL succeeded) {
                    (void)succeeded;
                    onDeletionComplete();
                }];
            }
            else
            {
                [torrent closeRemoveTorrent:deleteData];
            }
        }
    }
}

- (void)removeNoDelete:(id)sender
{
    [self removeTorrents:self.fTableView.selectedTorrents deleteData:NO];
}

- (void)removeDeleteData:(id)sender
{
    [self removeTorrents:self.fTableView.selectedTorrents deleteData:YES];
}

- (void)clearCompleted:(id)sender
{
    NSMutableArray<Torrent*>* torrents = [NSMutableArray array];

    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.finishedSeeding)
        {
            [torrents addObject:torrent];
        }
    }

    if ([self.fDefaults boolForKey:@"WarningRemoveCompleted"])
    {
        NSString *message, *info;
        if (torrents.count == 1)
        {
            NSString* torrentName = torrents[0].name;
            message = [NSString
                stringWithFormat:NSLocalizedString(@"Are you sure you want to remove \"%@\" from the transfer list?", "Remove completed confirm panel -> title"),
                                 torrentName];

            info = NSLocalizedString(
                @"Once removed, continuing the transfer will require the torrent file or magnet link.",
                "Remove completed confirm panel -> message");
        }
        else
        {
            message = [NSString localizedStringWithFormat:NSLocalizedString(
                                                              @"Are you sure you want to remove %lu completed transfers from the transfer list?",
                                                              "Remove completed confirm panel -> title"),
                                                          torrents.count];

            info = NSLocalizedString(
                @"Once removed, continuing the transfers will require the torrent files or magnet links.",
                "Remove completed confirm panel -> message");
        }

        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = message;
        alert.informativeText = info;
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:NSLocalizedString(@"Remove", "Remove completed confirm panel -> button")];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "Remove completed confirm panel -> button")];
        alert.showsSuppressionButton = YES;

        NSInteger const returnCode = [alert runModal];
        if (alert.suppressionButton.state)
        {
            [self.fDefaults setBool:NO forKey:@"WarningRemoveCompleted"];
        }

        if (returnCode != NSAlertFirstButtonReturn)
        {
            return;
        }
    }

    [self confirmRemoveTorrents:torrents deleteData:NO];
}

@end
