// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// RPC callback handling: libtransmission events (torrent added/removed/changed, session, etc.).

#import "ControllerPrivate.h"
#import "GroupsController.h"
#import "InfoWindowController.h"
#import "PrefsController.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"

#include <libtransmission/transmission.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (RPC)

- (void)rpcCallback:(tr_rpc_callback_type)type forTorrentStruct:(struct tr_torrent*)torrentStruct
{
    @autoreleasepool
    {
        __block Torrent* torrent = nil;
        if (torrentStruct != NULL && (type != TR_RPC_TORRENT_ADDED && type != TR_RPC_SESSION_CHANGED && type != TR_RPC_SESSION_CLOSE))
        {
            [self.fTorrents enumerateObjectsWithOptions:NSEnumerationConcurrent
                                             usingBlock:^(Torrent* checkTorrent, NSUInteger /*idx*/, BOOL* stop) {
                                                 if (torrentStruct == checkTorrent.torrentStruct)
                                                 {
                                                     torrent = checkTorrent;
                                                     *stop = YES;
                                                 }
                                             }];

            if (!torrent)
            {
                NSLog(@"No torrent found matching the given torrent struct from the RPC callback!");
                return;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            switch (type)
            {
            case TR_RPC_TORRENT_ADDED:
                {
                    tr_stat const* st = tr_torrentStat(torrentStruct);
                    uint64_t needed = st ? st->sizeWhenDone : 0;
                    auto const path = @(tr_torrentGetDownloadDir(torrentStruct));
                    [self autoDeleteOldTorrentsAtPath:path group:-1 forBytes:needed completion:^{
                        [self rpcAddTorrentStruct:torrentStruct];
                    }];
                }
                break;

            case TR_RPC_TORRENT_STARTED:
            case TR_RPC_TORRENT_STOPPED:
                [self rpcStartedStoppedTorrent:torrent];
                break;

            case TR_RPC_TORRENT_REMOVING:
                [self rpcRemoveTorrent:torrent deleteData:NO];
                break;

            case TR_RPC_TORRENT_TRASHING:
                [self rpcRemoveTorrent:torrent deleteData:YES];
                break;

            case TR_RPC_TORRENT_CHANGED:
                [self rpcChangedTorrent:torrent];
                break;

            case TR_RPC_TORRENT_MOVED:
                [self rpcMovedTorrent:torrent];
                break;

            case TR_RPC_SESSION_QUEUE_POSITIONS_CHANGED:
                [self rpcUpdateQueue];
                break;

            case TR_RPC_SESSION_CHANGED:
                [self.prefsController rpcUpdatePrefs];
                break;

            case TR_RPC_SESSION_CLOSE:
                self.fQuitRequested = YES;
                [NSApp terminate:self];
                break;

            default:
                NSAssert1(NO, @"Unknown RPC command received: %d", type);
            }
        });
    }
}

- (void)rpcAddTorrentStruct:(struct tr_torrent*)torrentStruct
{
    NSString* location = nil;
    if (tr_torrentGetDownloadDir(torrentStruct) != NULL)
    {
        location = @(tr_torrentGetDownloadDir(torrentStruct));
    }

    Torrent* torrent = [[Torrent alloc] initWithTorrentStruct:torrentStruct location:location lib:self.fLib];

    if ([GroupsController.groups usesCustomDownloadLocationForIndex:torrent.groupValue])
    {
        location = [GroupsController.groups customDownloadLocationForIndex:torrent.groupValue];
        [torrent changeDownloadFolderBeforeUsing:location determinationType:TorrentDeterminationAutomatic];
    }

    [torrent update];
    [self insertTorrentAtTop:torrent];

    if (!self.fAddingTransfers)
    {
        self.fAddingTransfers = [[NSMutableSet alloc] init];
    }
    [self.fAddingTransfers addObject:torrent];

    [self fullUpdateUI];
}

- (void)rpcRemoveTorrent:(Torrent*)torrent deleteData:(BOOL)deleteData
{
    [self confirmRemoveTorrents:@[ torrent ] deleteData:deleteData];
}

- (void)rpcStartedStoppedTorrent:(Torrent*)torrent
{
    [torrent update];

    [self updateUI];
    [self applyFilter];
    [self updateTorrentHistory];
}

- (void)rpcChangedTorrent:(Torrent*)torrent
{
    [torrent update];

    if ([self.fTableView.selectedTorrents containsObject:torrent])
    {
        [self.fInfoController updateInfoStats];
        [self.fInfoController updateOptions];
    }
}

- (void)rpcMovedTorrent:(Torrent*)torrent
{
    [torrent update];
    [torrent updateTimeMachineExclude];

    if ([self.fTableView.selectedTorrents containsObject:torrent])
    {
        [self.fInfoController updateInfoStats];
    }
}

- (void)rpcUpdateQueue
{
    [Torrent updateTorrents:self.fTorrents];

    NSSortDescriptor* descriptor = [NSSortDescriptor sortDescriptorWithKey:@"queuePosition" ascending:YES];
    NSArray* descriptors = @[ descriptor ];
    [self.fTorrents sortUsingDescriptors:descriptors];

    [self sortTorrentsAndIncludeQueueOrder:YES];
}

@end
#pragma clang diagnostic pop
