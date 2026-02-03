// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// User notification handling: UNUserNotificationCenter delegate and activation (show in Finder, select in table).

#import "ControllerPrivate.h"
#import "FilterBarController.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"

@import UserNotifications;

@implementation Controller (Notifications)

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    completionHandler(-1);
}

- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    if (!response.notification.request.content.userInfo.count)
    {
        completionHandler();
        return;
    }

    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier])
    {
        [self didActivateNotificationByDefaultActionWithUserInfo:response.notification.request.content.userInfo];
    }
    else if ([response.actionIdentifier isEqualToString:@"actionShow"])
    {
        [self didActivateNotificationByActionShowWithUserInfo:response.notification.request.content.userInfo];
    }
    completionHandler();
}

- (void)didActivateNotificationByActionShowWithUserInfo:(NSDictionary<NSString*, id>*)userInfo
{
    Torrent* torrent = [self torrentForHash:userInfo[@"Hash"]];
    NSString* location = torrent.dataLocation;
    if (!location)
    {
        location = userInfo[@"Location"];
    }
    if (location)
    {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:location] ]];
    }
}

- (void)didActivateNotificationByDefaultActionWithUserInfo:(NSDictionary<NSString*, id>*)userInfo
{
    Torrent* torrent = [self torrentForHash:userInfo[@"Hash"]];
    if (!torrent)
    {
        return;
    }
    NSInteger row = [self.fTableView rowForItem:torrent];
    if (row == -1)
    {
        if ([self.fDefaults boolForKey:@"SortByGroup"])
        {
            __block TorrentGroup* parent = nil;
            [self.fDisplayedTorrents enumerateObjectsWithOptions:NSEnumerationConcurrent
                                                      usingBlock:^(TorrentGroup* group, NSUInteger /*idx*/, BOOL* stop) {
                                                          if ([group.torrents containsObject:torrent])
                                                          {
                                                              parent = group;
                                                              *stop = YES;
                                                          }
                                                      }];
            if (parent)
            {
                [[self.fTableView animator] expandItem:parent];
                row = [self.fTableView rowForItem:torrent];
            }
        }

        if (row == -1)
        {
            NSAssert([self.fDefaults boolForKey:@"FilterBar"], @"expected the filter to be enabled");
            [self.fFilterBar reset];

            row = [self.fTableView rowForItem:torrent];

            if ([self.fDefaults boolForKey:@"SortByGroup"])
            {
                __block TorrentGroup* parent = nil;
                [self.fDisplayedTorrents enumerateObjectsWithOptions:NSEnumerationConcurrent
                                                          usingBlock:^(TorrentGroup* group, NSUInteger /*idx*/, BOOL* stop) {
                                                              if ([group.torrents containsObject:torrent])
                                                              {
                                                                  parent = group;
                                                                  *stop = YES;
                                                              }
                                                          }];
                if (parent)
                {
                    [[self.fTableView animator] expandItem:parent];
                    row = [self.fTableView rowForItem:torrent];
                }
            }
        }
    }

    NSAssert1(row != -1, @"expected a row to be found for torrent %@", torrent);

    [self showMainWindow:nil];
    [self.fTableView selectAndScrollToRow:row];
}

@end
