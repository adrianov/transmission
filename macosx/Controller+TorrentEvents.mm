// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Torrent lifecycle events: lookup by hash, download complete, restarted, seeding complete.

#import "ControllerPrivate.h"
#import "Badger.h"
#import "DjvuConverter.h"
#import "Fb2Converter.h"
#import "InfoWindowController.h"
#import "Torrent.h"
#import "TorrentTableView.h"

@import UserNotifications;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (TorrentEvents)

- (Torrent*)torrentForHash:(NSString*)hash
{
    NSParameterAssert(hash != nil);

    __block Torrent* torrent = nil;
    [self.fTorrents enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(Torrent* obj, NSUInteger /*idx*/, BOOL* stop) {
        if ([obj.hashString isEqualToString:hash])
        {
            torrent = obj;
            *stop = YES;
        }
    }];
    return torrent;
}

- (void)torrentFinishedDownloading:(NSNotification*)notification
{
    Torrent* torrent = notification.object;

    if ([notification.userInfo[@"WasRunning"] boolValue])
    {
        if (!self.fSoundPlaying && [self.fDefaults boolForKey:@"PlayDownloadSound"])
        {
            NSSound* sound;
            if ((sound = [NSSound soundNamed:[self.fDefaults stringForKey:@"DownloadSound"]]))
            {
                sound.delegate = self;
                self.fSoundPlaying = YES;
                [sound play];
            }
        }

        NSString* title = NSLocalizedString(@"Download Complete", "notification title");
        NSString* body = torrent.name;
        NSString* location = torrent.dataLocation;
        NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObject:torrent.hashString forKey:@"Hash"];
        if (location)
        {
            userInfo[@"Location"] = location;
        }

        NSString* identifier = [@"Download Complete " stringByAppendingString:torrent.hashString];
        UNMutableNotificationContent* content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = body;
        content.categoryIdentifier = @"categoryShow";
        content.userInfo = userInfo;

        UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];

        if (!self.fWindow.mainWindow)
        {
            [self.fBadger addCompletedTorrent:torrent];
        }

        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished"
                                                                     object:torrent.dataLocation];
    }

    if ([self.fDefaults boolForKey:@"AutoConvertDjvu"])
    {
        [DjvuConverter checkAndConvertCompletedFiles:torrent];
        [Fb2Converter checkAndConvertCompletedFiles:torrent];
    }

    [self fullUpdateUI];
    [self selectAndScrollToTorrent:torrent];
}

- (void)torrentRestartedDownloading:(NSNotification*)notification
{
    [self fullUpdateUI];
}

- (void)torrentFinishedSeeding:(NSNotification*)notification
{
    Torrent* torrent = notification.object;

    if (!self.fSoundPlaying && [self.fDefaults boolForKey:@"PlaySeedingSound"])
    {
        NSSound* sound;
        if ((sound = [NSSound soundNamed:[self.fDefaults stringForKey:@"SeedingSound"]]))
        {
            sound.delegate = self;
            self.fSoundPlaying = YES;
            [sound play];
        }
    }

    NSString* title = NSLocalizedString(@"Seeding Complete", "notification title");
    NSString* body = torrent.name;
    NSString* location = torrent.dataLocation;
    NSMutableDictionary* userInfo = [NSMutableDictionary dictionaryWithObject:torrent.hashString forKey:@"Hash"];
    if (location)
    {
        userInfo[@"Location"] = location;
    }

    NSString* identifier = [@"Seeding Complete " stringByAppendingString:torrent.hashString];
    UNMutableNotificationContent* content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.categoryIdentifier = @"categoryShow";
    content.userInfo = userInfo;

    UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];

    if (torrent.removeWhenFinishSeeding)
    {
        [self confirmRemoveTorrents:@[ torrent ] deleteData:NO];
    }
    else
    {
        if (!self.fWindow.mainWindow)
        {
            [self.fBadger addCompletedTorrent:torrent];
        }

        [self fullUpdateUI];

        if ([self.fTableView.selectedTorrents containsObject:torrent])
        {
            [self.fInfoController updateInfoStats];
            [self.fInfoController updateOptions];
        }
    }
}

@end
#pragma clang diagnostic pop
