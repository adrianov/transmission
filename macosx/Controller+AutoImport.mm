// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Watch folder and auto-add torrent files. Uses a serial queue and delayed scan on VDKQueue events.

@import UserNotifications;

#include <libtransmission/torrent-metainfo.h>

#import "ControllerPrivate.h"
#import "VDKQueue.h"

#import "CocoaCompatibility.h"

static uint64_t sAutoImportScanCounter = 0;

static BOOL autoImportDebugLoggingEnabled()
{
    return [NSUserDefaults.standardUserDefaults boolForKey:@"AutoImportDebugLogging"];
}

#define AUTOIMPORT_LOG(...)        \
    do                             \
    {                              \
        if (autoImportDebugLoggingEnabled()) \
        {                          \
            NSLog(__VA_ARGS__);    \
        }                          \
    } while (0)

static dispatch_queue_t autoImportQueue()
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.transmissionbt.autoimport", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@implementation Controller (AutoImport)

- (void)VDKQueue:(VDKQueue*)queue receivedNotification:(NSString*)notification forPath:(NSString*)fpath
{
    if (![self.fDefaults boolForKey:@"AutoImport"] || ![self.fDefaults stringForKey:@"AutoImportDirectory"])
    {
        return;
    }

    AUTOIMPORT_LOG(@"AutoImport watcher event: note=%@ path=%@", notification ?: @"(null)", fpath ?: @"(null)");

    if (self.fAutoImportTimer.valid)
    {
        AUTOIMPORT_LOG(@"AutoImport: invalidating pending delayed scan timer");
        [self.fAutoImportTimer invalidate];
    }

    self.fAutoImportTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self
                                                           selector:@selector(checkAutoImportDirectoryFromTimer:)
                                                           userInfo:@{
                                                               @"notification" : notification ?: @"(null)",
                                                               @"path" : fpath ?: @"(null)"
                                                           }
                                                            repeats:NO];
    AUTOIMPORT_LOG(@"AutoImport: scheduled delayed scan in 10s");

    [self checkAutoImportDirectoryWithReason:@"watcher-immediate"];
}

- (void)changeAutoImport
{
    if (self.fAutoImportTimer.valid)
    {
        [self.fAutoImportTimer invalidate];
    }
    self.fAutoImportTimer = nil;
    self.fAutoImportedNames = nil;
    [self checkAutoImportDirectoryWithReason:@"settings-change"];
}

- (void)checkAutoImportDirectoryFromTimer:(NSTimer*)timer
{
    NSDictionary* userInfo = timer.userInfo;
    NSString* reason = [NSString
        stringWithFormat:@"watcher-delayed note=%@ path=%@",
                         userInfo[@"notification"] ?: @"(null)",
                         userInfo[@"path"] ?: @"(null)"];
    [self checkAutoImportDirectoryWithReason:reason];
}

- (void)checkAutoImportDirectory
{
    [self checkAutoImportDirectoryWithReason:@"unspecified"];
}

- (void)checkAutoImportDirectoryWithReason:(NSString*)reason
{
    uint64_t const scanId = ++sAutoImportScanCounter;
    CFAbsoluteTime const requestStart = CFAbsoluteTimeGetCurrent();

    NSString* path;
    if (![self.fDefaults boolForKey:@"AutoImport"] || !(path = [self.fDefaults stringForKey:@"AutoImportDirectory"]))
    {
        AUTOIMPORT_LOG(@"AutoImport[%llu] skip reason=%@: disabled or path missing", (unsigned long long)scanId, reason ?: @"(null)");
        return;
    }

    NSString* const pathSnapshot = path.stringByExpandingTildeInPath;
    NSString* const reasonSnapshot = [reason copy] ?: @"(null)";
    AUTOIMPORT_LOG(@"AutoImport[%llu] queued reason=%@ path=%@", (unsigned long long)scanId, reasonSnapshot, pathSnapshot);

    __weak typeof(self) weakSelf = self;
    dispatch_async(autoImportQueue(), ^{
        CFAbsoluteTime const bgStart = CFAbsoluteTimeGetCurrent();
        NSArray<NSString*>* importedNames = [NSFileManager.defaultManager contentsOfDirectoryAtPath:pathSnapshot error:NULL];
        if (!importedNames)
        {
            AUTOIMPORT_LOG(@"AutoImport[%llu] list failed reason=%@ path=%@ after %.3fs",
                           (unsigned long long)scanId,
                           reasonSnapshot,
                           pathSnapshot,
                           CFAbsoluteTimeGetCurrent() - bgStart);
            return;
        }

        __block BOOL shouldContinue = NO;
        __block NSArray<NSString*>* previousImportedNames = @[];
        dispatch_sync(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf)
            {
                return;
            }

            NSString* currentPath = nil;
            if ([strongSelf.fDefaults boolForKey:@"AutoImport"] &&
                (currentPath = [strongSelf.fDefaults stringForKey:@"AutoImportDirectory"]) != nil &&
                [currentPath.stringByExpandingTildeInPath isEqualToString:pathSnapshot])
            {
                previousImportedNames = [strongSelf.fAutoImportedNames copy] ?: @[];
                shouldContinue = YES;
            }
        });

        if (!shouldContinue)
        {
            AUTOIMPORT_LOG(@"AutoImport[%llu] stale scan ignored reason=%@ path=%@",
                           (unsigned long long)scanId,
                           reasonSnapshot,
                           pathSnapshot);
            return;
        }

        NSMutableArray<NSString*>* newNames = [importedNames mutableCopy];
        [newNames removeObjectsInArray:previousImportedNames];

        NSMutableArray<NSDictionary<NSString*, NSString*>*>* filesToImport = [NSMutableArray array];
        NSMutableArray<NSString*>* emptyFiles = [NSMutableArray array];
        NSUInteger hiddenCount = 0;
        NSUInteger typeMismatchCount = 0;
        NSUInteger parseFailCount = 0;

        for (NSString* file in newNames)
        {
            if ([file hasPrefix:@"."])
            {
                ++hiddenCount;
                continue;
            }

            NSString* fullFile = [pathSnapshot stringByAppendingPathComponent:file];
            BOOL const hasTorrentExtension = [fullFile.pathExtension caseInsensitiveCompare:@"torrent"] == NSOrderedSame;
            if (!hasTorrentExtension)
            {
                NSURL* fileURL = [NSURL fileURLWithPath:fullFile];
                NSString* contentType = nil;
                [fileURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:NULL];
                if (![contentType isEqualToString:@"org.bittorrent.torrent"])
                {
                    ++typeMismatchCount;
                    continue;
                }
            }

            NSDictionary<NSFileAttributeKey, id>* fileAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:fullFile
                                                                                                                  error:nil];
            if (fileAttributes.fileSize == 0)
            {
                [emptyFiles addObject:file];
                continue;
            }

            auto metainfo = tr_torrent_metainfo{};
            if (!metainfo.parse_torrent_file(fullFile.UTF8String))
            {
                ++parseFailCount;
                continue;
            }

            [filesToImport addObject:@{ @"name" : file, @"path" : fullFile }];
        }

        AUTOIMPORT_LOG(@"AutoImport[%llu] scan done reason=%@ path=%@ listed=%lu previous=%lu new=%lu importable=%lu hidden=%lu type_skip=%lu empty=%lu parse_fail=%lu bg=%.3fs",
                       (unsigned long long)scanId,
                       reasonSnapshot,
                       pathSnapshot,
                       (unsigned long)importedNames.count,
                       (unsigned long)previousImportedNames.count,
                       (unsigned long)newNames.count,
                       (unsigned long)filesToImport.count,
                       (unsigned long)hiddenCount,
                       (unsigned long)typeMismatchCount,
                       (unsigned long)emptyFiles.count,
                       (unsigned long)parseFailCount,
                       CFAbsoluteTimeGetCurrent() - bgStart);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf)
            {
                return;
            }

            NSString* currentPath = nil;
            if (![strongSelf.fDefaults boolForKey:@"AutoImport"] ||
                (currentPath = [strongSelf.fDefaults stringForKey:@"AutoImportDirectory"]) == nil ||
                ![currentPath.stringByExpandingTildeInPath isEqualToString:pathSnapshot])
            {
                AUTOIMPORT_LOG(@"AutoImport[%llu] apply skipped (stale settings) reason=%@ path=%@",
                               (unsigned long long)scanId,
                               reasonSnapshot,
                               pathSnapshot);
                return;
            }

            if (!strongSelf.fAutoImportedNames)
            {
                strongSelf.fAutoImportedNames = [[NSMutableArray alloc] init];
            }

            [strongSelf.fAutoImportedNames setArray:importedNames];
            if (emptyFiles.count > 0)
            {
                [strongSelf.fAutoImportedNames removeObjectsInArray:emptyFiles];
            }

            NSUInteger importedCount = 0;
            for (NSDictionary<NSString*, NSString*>* fileToImport in filesToImport)
            {
                NSString* file = fileToImport[@"name"];
                NSString* fullFile = fileToImport[@"path"];
                [strongSelf openFiles:@[ fullFile ] addType:AddTypeAuto forcePath:nil];
                ++importedCount;
                AUTOIMPORT_LOG(@"AutoImport[%llu] imported %@", (unsigned long long)scanId, file);

                NSString* notificationTitle = NSLocalizedString(@"Torrent File Auto Added", "notification title");
                NSString* identifier = [@"Torrent File Auto Added " stringByAppendingString:file];
                UNMutableNotificationContent* content = [UNMutableNotificationContent new];
                content.title = notificationTitle;
                content.body = file;
                UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
                [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
            }

            AUTOIMPORT_LOG(@"AutoImport[%llu] apply complete reason=%@ imported=%lu total=%.3fs",
                           (unsigned long long)scanId,
                           reasonSnapshot,
                           (unsigned long)importedCount,
                           CFAbsoluteTimeGetCurrent() - requestStart);
        });
    });
}

- (void)beginCreateFile:(NSNotification*)notification
{
    if (![self.fDefaults boolForKey:@"AutoImport"])
    {
        return;
    }

    NSString* location = ((NSURL*)notification.object).path;
    NSString* path = [self.fDefaults stringForKey:@"AutoImportDirectory"];

    if (location && path && [location.stringByDeletingLastPathComponent.stringByExpandingTildeInPath isEqualToString:path.stringByExpandingTildeInPath])
    {
        [self.fAutoImportedNames addObject:location.lastPathComponent];
    }
}

@end
