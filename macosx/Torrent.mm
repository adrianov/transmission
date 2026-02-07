// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <optional>
#include <vector>

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfloat-equal"
#endif
#include <fmt/format.h>
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#include <libtransmission/transmission.h>

#include <libtransmission/error.h>
#include <libtransmission/log.h>
#include <libtransmission/utils.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Torrent.h"
#import "TorrentPrivate.h"
#import "IINAWatchHelper.h"
#import "GroupsController.h"
#import "FileListNode.h"
#import "NSStringAdditions.h"
#import "TrackerNode.h"
#import "DjvuConverter.h"
#import "Fb2Converter.h"

NSString* const kTorrentDidChangeGroupNotification = @"TorrentDidChangeGroup";

static int const kETAIdleDisplaySec = 2 * 60;

static dispatch_queue_t timeMachineExcludeQueue;

void renameCallback(tr_torrent* /*torrent*/, char const* oldPathCharString, char const* newNameCharString, int error, void* contextInfo)
{
    @autoreleasepool
    {
        NSString* oldPath = @(oldPathCharString);
        NSString* newName = @(newNameCharString);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary* contextDict = (__bridge_transfer NSDictionary*)contextInfo;
            Torrent* torrentObject = contextDict[@"Torrent"];
            [torrentObject renameFinished:error == 0 nodes:contextDict[@"Nodes"]
                        completionHandler:contextDict[@"CompletionHandler"]
                                  oldPath:oldPath
                                  newName:newName];
        });
    }
}

bool trashDataFile(char const* filename, void* /*user_data*/, tr_error* error)
{
    if (filename == NULL)
    {
        return false;
    }

    @autoreleasepool
    {
        NSError* localError;
        if (![Torrent trashFile:@(filename) error:&localError])
        {
            error->set(static_cast<int>(localError.code), localError.description.UTF8String);
            return false;
        }
    }

    return true;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation Torrent

- (uint64_t)sizeWhenDone
{
    tr_stat const* st = tr_torrentStat(self.fHandle);
    return st ? (uint64_t)st->sizeWhenDone : 0;
}

+ (void)initialize
{
    if (self != [Torrent self])
        return;

    // DISPATCH_QUEUE_SERIAL because DISPATCH_QUEUE_CONCURRENT is limited to 64 simultaneous torrent dispatch_async
    timeMachineExcludeQueue = dispatch_queue_create("updateTimeMachineExclude", DISPATCH_QUEUE_SERIAL);
}

- (void)dealloc
{
    // Remove all notification observers to prevent crashes when notifications fire after dealloc
    [NSNotificationCenter.defaultCenter removeObserver:self];
    // Note: Don't call DjvuConverter clearTrackingForTorrent here - it accesses fHandle which may be invalid
}

- (instancetype)initWithPath:(NSString*)path
                    location:(NSString*)location
           deleteTorrentFile:(BOOL)torrentDelete
                         lib:(tr_session*)lib
{
    self = [self initWithPath:path hash:nil torrentStruct:NULL magnetAddress:nil lib:lib groupValue:nil
        removeWhenFinishSeeding:nil
                 downloadFolder:location
         legacyIncompleteFolder:nil];

    if (self)
    {
        if (torrentDelete && ![self.torrentLocation isEqualToString:path])
        {
            [Torrent trashFile:path error:nil];
        }
    }
    return self;
}

- (instancetype)initWithTorrentStruct:(tr_torrent*)torrentStruct location:(NSString*)location lib:(tr_session*)lib
{
    self = [self initWithPath:nil hash:nil torrentStruct:torrentStruct magnetAddress:nil lib:lib groupValue:nil
        removeWhenFinishSeeding:nil
                 downloadFolder:location
         legacyIncompleteFolder:nil];

    return self;
}

- (instancetype)initWithMagnetAddress:(NSString*)address location:(NSString*)location lib:(tr_session*)lib
{
    self = [self initWithPath:nil hash:nil torrentStruct:nil magnetAddress:address lib:lib groupValue:nil
        removeWhenFinishSeeding:nil
                 downloadFolder:location
         legacyIncompleteFolder:nil];

    return self;
}

- (void)setResumeStatusForTorrent:(Torrent*)torrent withHistory:(NSDictionary*)history forcePause:(BOOL)pause
{
    //restore GroupValue
    torrent.groupValue = [history[@"GroupValue"] intValue];

    //start transfer
    NSNumber* active;
    if (!pause && (active = history[@"Active"]) && active.boolValue)
    {
        [torrent startTransferNoQueue];
    }

    NSNumber* ratioLimit;
    if ((ratioLimit = history[@"RatioLimit"]))
    {
        self.ratioLimit = ratioLimit.floatValue;
    }
}

- (NSDictionary*)history
{
    return @{
        @"TorrentHash" : self.hashString,
        @"Active" : @(self.active),
        @"WaitToStart" : @(self.waitingToStart),
        @"GroupValue" : @(self.groupValue),
        @"RemoveWhenFinishSeeding" : @(_removeWhenFinishSeeding)
    };
}

- (NSString*)description
{
    return [@"Torrent: " stringByAppendingString:self.name];
}

- (id)copyWithZone:(NSZone*)zone
{
    return self;
}

- (void)closeRemoveTorrent:(BOOL)trashFiles
{
    [self closeRemoveTorrent:trashFiles completionHandler:nil];
}

- (void)closeRemoveTorrent:(BOOL)trashFiles completionHandler:(void (^)(BOOL succeeded))completionHandler
{
    //allow the file to be indexed by Time Machine
    [self setTimeMachineExclude:NO];

    // Remove notification observers BEFORE invalidating fHandle to prevent crashes
    [NSNotificationCenter.defaultCenter removeObserver:self name:@"DjvuConversionComplete" object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:@"Fb2ConversionComplete" object:nil];

    // Delete converted files (PDF from DJVU, EPUB from FB2) when trashing data
    if (trashFiles)
    {
        for (NSString* path in [DjvuConverter convertedFilesForTorrent:self])
            [Torrent trashFile:path error:nil];
        for (NSString* path in [Fb2Converter convertedFilesForTorrent:self])
            [Torrent trashFile:path error:nil];
    }

    // Clear conversion tracking
    [DjvuConverter clearTrackingForTorrent:self];
    [Fb2Converter clearTrackingForTorrent:self];

    tr_torrent_remove_done_func callback = nullptr;
    void* callback_user_data = nullptr;

    if (completionHandler != nil)
    {
        // Capture completionHandler in a block that will be called from the session thread
        void (^completionBlock)(BOOL) = [completionHandler copy];
        callback = [](tr_torrent_id_t /*id*/, bool succeeded, void* user_data)
        {
            void (^block)(BOOL) = (__bridge_transfer void (^)(BOOL))user_data;
            dispatch_async(dispatch_get_main_queue(), ^{
                block(succeeded);
            });
        };
        callback_user_data = (__bridge_retained void*)completionBlock;
    }

    tr_torrentRemove(self.fHandle, trashFiles, trashDataFile, nullptr, callback, callback_user_data);
}

- (void)changeDownloadFolderBeforeUsing:(NSString*)folder determinationType:(TorrentDeterminationType)determinationType
{
    //if data existed in original download location, unexclude it before changing the location
    [self setTimeMachineExclude:NO];

    tr_torrentSetDownloadDir(self.fHandle, folder.UTF8String);

    self.fDownloadFolderDetermination = determinationType;
}

- (NSString*)currentDirectory
{
    return @(tr_torrentGetCurrentDir(self.fHandle));
}

- (void)getAvailability:(int8_t*)tab size:(int)size
{
    tr_torrentAvailability(self.fHandle, tab, size);
}

- (void)getAmountFinished:(float*)tab size:(int)size
{
    tr_torrentAmountFinished(self.fHandle, tab, size);
}

- (NSIndexSet*)previousFinishedPieces
{
    //if the torrent hasn't been seen in a bit, and therefore hasn't been refreshed, return nil
    if (self.fPreviousFinishedIndexesDate && self.fPreviousFinishedIndexesDate.timeIntervalSinceNow > -2.0)
    {
        return self.fPreviousFinishedIndexes;
    }
    else
    {
        return nil;
    }
}

- (void)setPreviousFinishedPieces:(NSIndexSet*)indexes
{
    self.fPreviousFinishedIndexes = indexes;

    self.fPreviousFinishedIndexesDate = indexes != nil ? [[NSDate alloc] init] : nil;
}

- (void)update
{
    [Torrent updateTorrents:@[ self ]];
}

+ (void)updateTorrents:(NSArray<Torrent*>*)torrents
{
    if (torrents == nil || torrents.count == 0)
    {
        return;
    }

    std::vector<Torrent*> torrent_objects;
    torrent_objects.reserve(torrents.count);

    std::vector<tr_torrent*> torrent_handles;
    torrent_handles.reserve(torrents.count);

    std::vector<BOOL> was_transmitting;
    was_transmitting.reserve(torrents.count);

    for (Torrent* torrent in torrents)
    {
        if (torrent == nil || torrent.fHandle == nullptr)
        {
            continue;
        }

        torrent_objects.emplace_back(torrent);
        torrent_handles.emplace_back(torrent.fHandle);
        was_transmitting.emplace_back(torrent.fStat != nullptr && torrent.transmitting);
    }

    if (torrent_handles.empty())
    {
        return;
    }

    auto const stats = tr_torrentStat(torrent_handles.data(), torrent_handles.size());

    // Assign stats and post notifications.
    for (size_t i = 0, n = torrent_objects.size(); i < n; ++i)
    {
        Torrent* const torrent = torrent_objects[i];
        torrent.fStat = stats[i];
        torrent.fStatsGeneration++;

        // Clear disk space flag when torrent is no longer stopped
        if (torrent.fStat->activity != TR_STATUS_STOPPED)
        {
            torrent.fPausedForDiskSpace = NO;
            torrent.fDiskSpaceDialogShown = NO;
        }

        //make sure the "active" filter is updated when transmitting changes
        if (was_transmitting[i] != torrent.transmitting)
        {
            //posting asynchronously with coalescing to prevent stack overflow on lots of torrents changing state at the same time
            [NSNotificationQueue.defaultQueue enqueueNotification:[NSNotification notificationWithName:@"UpdateTorrentsState" object:nil]
                                                     postingStyle:NSPostASAP
                                                     coalesceMask:NSNotificationCoalescingOnName
                                                         forModes:nil];
        }
    }
}

- (void)startTransferIgnoringQueue:(BOOL)ignoreQueue
{
    // Always bypass throttle when explicitly starting - user expects fresh check
    if ([self alertForRemainingDiskSpaceBypassThrottle:YES])
    {
        ignoreQueue ? tr_torrentStartNow(self.fHandle) : tr_torrentStart(self.fHandle);
        [self update];

        //capture, specifically, stop-seeding settings changing to unlimited
        [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateOptions" object:nil];
    }
}

- (void)startTransferNoQueue
{
    [self startTransferIgnoringQueue:YES];
}

- (void)startTransfer
{
    [self startTransferIgnoringQueue:NO];
}

- (void)startMagnetTransferAfterMetaDownload
{
    // Always bypass throttle when explicitly starting - user expects fresh check
    if ([self alertForRemainingDiskSpaceBypassThrottle:YES])
    {
        tr_torrentStart(self.fHandle);
        [self update];

        //capture, specifically, stop-seeding settings changing to unlimited
        [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateOptions" object:nil];
    }
}

- (void)stopTransfer
{
    tr_torrentStop(self.fHandle);
    [self update];
}

- (void)sleep
{
    if ((self.fResumeOnWake = self.active))
    {
        tr_torrentStop(self.fHandle);
    }
}

- (void)wakeUp
{
    if (self.fResumeOnWake)
    {
        tr_logAddTrace("restarting because of wakeup", tr_torrentName(self.fHandle));
        tr_torrentStart(self.fHandle);
    }
}

- (NSUInteger)queuePosition
{
    return self.fStat->queuePosition;
}

- (void)setQueuePosition:(NSUInteger)index
{
    tr_torrentSetQueuePosition(self.fHandle, index);
}

- (void)manualAnnounce
{
    tr_torrentManualUpdate(self.fHandle);
}

- (BOOL)canManualAnnounce
{
    return tr_torrentCanManualUpdate(self.fHandle);
}

- (void)resetCache
{
    tr_torrentVerify(self.fHandle);
    [self update];
}

- (BOOL)isMagnet
{
    return !tr_torrentHasMetadata(self.fHandle);
}

- (NSString*)magnetLink
{
    return @(tr_torrentGetMagnetLink(self.fHandle).c_str());
}

- (CGFloat)ratio
{
    return self.fStat->ratio;
}

- (tr_ratiolimit)ratioSetting
{
    return tr_torrentGetRatioMode(self.fHandle);
}

- (void)setRatioSetting:(tr_ratiolimit)setting
{
    tr_torrentSetRatioMode(self.fHandle, setting);
}

- (CGFloat)ratioLimit
{
    return tr_torrentGetRatioLimit(self.fHandle);
}

- (void)setRatioLimit:(CGFloat)limit
{
    NSParameterAssert(limit >= 0);

    tr_torrentSetRatioLimit(self.fHandle, limit);
}

- (CGFloat)progressStopRatio
{
    return self.fStat->seedRatioPercentDone;
}

- (tr_idlelimit)idleSetting
{
    return tr_torrentGetIdleMode(self.fHandle);
}

- (void)setIdleSetting:(tr_idlelimit)setting
{
    tr_torrentSetIdleMode(self.fHandle, setting);
}

- (NSUInteger)idleLimitMinutes
{
    return tr_torrentGetIdleLimit(self.fHandle);
}

- (void)setIdleLimitMinutes:(NSUInteger)limit
{
    NSParameterAssert(limit > 0);

    tr_torrentSetIdleLimit(self.fHandle, limit);
}

- (BOOL)usesSpeedLimit:(BOOL)upload
{
    return tr_torrentUsesSpeedLimit(self.fHandle, upload ? TR_UP : TR_DOWN);
}

- (void)setUseSpeedLimit:(BOOL)use upload:(BOOL)upload
{
    tr_torrentUseSpeedLimit(self.fHandle, upload ? TR_UP : TR_DOWN, use);
}

- (NSUInteger)speedLimit:(BOOL)upload
{
    return tr_torrentGetSpeedLimit_KBps(self.fHandle, upload ? TR_UP : TR_DOWN);
}

- (void)setSpeedLimit:(NSUInteger)limit upload:(BOOL)upload
{
    tr_torrentSetSpeedLimit_KBps(self.fHandle, upload ? TR_UP : TR_DOWN, limit);
}

- (BOOL)usesGlobalSpeedLimit
{
    return tr_torrentUsesSessionLimits(self.fHandle);
}

- (void)setUsesGlobalSpeedLimit:(BOOL)use
{
    tr_torrentUseSessionLimits(self.fHandle, use);
}

- (void)setMaxPeerConnect:(uint16_t)count
{
    NSParameterAssert(count > 0);

    tr_torrentSetPeerLimit(self.fHandle, count);
}

- (uint16_t)maxPeerConnect
{
    return tr_torrentGetPeerLimit(self.fHandle);
}
- (BOOL)waitingToStart
{
    return self.fStat->activity == TR_STATUS_DOWNLOAD_WAIT || self.fStat->activity == TR_STATUS_SEED_WAIT;
}

- (tr_priority_t)priority
{
    return tr_torrentGetPriority(self.fHandle);
}

- (void)setPriority:(tr_priority_t)priority
{
    return tr_torrentSetPriority(self.fHandle, priority);
}

+ (BOOL)trashFile:(NSString*)path error:(NSError**)error
{
    NSError* localError;
    if ([NSFileManager.defaultManager removeItemAtPath:path error:&localError])
    {
        NSLog(@"Old removed %@", path);
        return YES;
    }

    NSLog(@"Old could not be removed %@: %@", path, localError.localizedDescription);
    if (error != nil)
    {
        *error = localError;
    }

    return NO;
}

- (void)moveTorrentDataFileTo:(NSString*)folder
{
    NSString* oldFolder = self.currentDirectory;
    if ([oldFolder isEqualToString:folder])
    {
        return;
    }

    //check if moving inside itself
    NSArray *oldComponents = oldFolder.pathComponents, *newComponents = folder.pathComponents;
    NSUInteger const oldCount = oldComponents.count;

    if (oldCount < newComponents.count && [newComponents[oldCount] isEqualToString:self.name] && [folder hasPrefix:oldFolder])
    {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"A folder cannot be moved to inside itself.", "Move inside itself alert -> title");
        alert.informativeText = [NSString
            stringWithFormat:NSLocalizedString(@"The move operation of \"%@\" cannot be done.", "Move inside itself alert -> message"),
                             self.name];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", "Move inside itself alert -> button")];

        [alert runModal];

        return;
    }

    __block int volatile status;
    tr_torrentSetLocation(self.fHandle, folder.UTF8String, YES, &status);

    NSString* torrentName = self.name;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (status == TR_LOC_MOVING)
        {
            [NSThread sleepForTimeInterval:0.05];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == TR_LOC_DONE)
            {
                [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateStats" object:nil];
            }
            else
            {
                NSAlert* alert = [[NSAlert alloc] init];
                alert.messageText = NSLocalizedString(@"There was an error moving the data file.", "Move error alert -> title");
                alert.informativeText = [NSString
                    stringWithFormat:NSLocalizedString(@"The move operation of \"%@\" cannot be done.", "Move error alert -> message"),
                                     torrentName];
                [alert addButtonWithTitle:NSLocalizedString(@"OK", "Move error alert -> button")];

                [alert runModal];
            }

            [self updateTimeMachineExclude];
        });
    });
}

- (void)copyTorrentFileTo:(NSString*)path
{
    NSString* sourcePath = self.torrentLocation;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [NSFileManager.defaultManager copyItemAtPath:sourcePath toPath:path error:NULL];
    });
}

- (NSString*)name
{
    return @(tr_torrentName(self.fHandle));
}

- (NSString*)displayName
{
    if (!self.fDisplayName)
    {
        // Check for episode title first
        NSString* episodeTitle = [self.name humanReadableEpisodeTitleWithTorrentName:self.name];
        if (episodeTitle)
        {
            self.fDisplayName = episodeTitle;
        }
        else
        {
            // Always regenerate to ensure latest formatting rules are applied
            self.fCachedHumanReadableTitle = self.name.humanReadableTitle;
            self.fDisplayName = self.fCachedHumanReadableTitle;
        }
    }
    return self.fDisplayName;
}

- (BOOL)isFolder
{
    return tr_torrentView(self.fHandle).is_folder;
}

- (uint64_t)size
{
    return tr_torrentView(self.fHandle).total_size;
}

- (uint64_t)sizeLeft
{
    return self.fStat->leftUntilDone;
}

- (NSMutableArray*)allTrackerStats
{
    auto const count = tr_torrentTrackerCount(self.fHandle);
    auto tier = std::optional<int>{};

    NSMutableArray* trackers = [NSMutableArray arrayWithCapacity:count * 2];

    for (size_t i = 0; i < count; ++i)
    {
        auto const tracker = tr_torrentTracker(self.fHandle, i);

        if (!tier || tier != tracker.tier)
        {
            tier = tracker.tier;
            [trackers addObject:@{ @"Tier" : @(tracker.tier + 1), @"Name" : self.name }];
        }

        auto* tracker_node = [[TrackerNode alloc] initWithTrackerView:&tracker torrent:self];
        [trackers addObject:tracker_node];
    }

    return trackers;
}

- (NSArray<NSString*>*)allTrackersFlat
{
    auto const n = tr_torrentTrackerCount(self.fHandle);
    NSMutableArray* allTrackers = [NSMutableArray arrayWithCapacity:n];

    for (size_t i = 0; i < n; ++i)
    {
        [allTrackers addObject:@(tr_torrentTracker(self.fHandle, i).announce)];
    }

    return allTrackers;
}

- (BOOL)addTrackerToNewTier:(NSString*)new_tracker
{
    new_tracker = [new_tracker stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([new_tracker rangeOfString:@"://"].location == NSNotFound)
    {
        new_tracker = [@"http://" stringByAppendingString:new_tracker];
    }

    auto const old_list = tr_torrentGetTrackerList(self.fHandle);
    auto const new_list = fmt::format(FMT_STRING("{:s}\n\n{:s}"), old_list, new_tracker.UTF8String);
    BOOL const success = tr_torrentSetTrackerList(self.fHandle, new_list.c_str());

    return success;
}

- (void)removeTrackers:(NSSet*)trackers
{
    auto new_list = std::string{};
    auto current_tier = std::optional<tr_tracker_tier_t>{};

    for (size_t i = 0, n = tr_torrentTrackerCount(self.fHandle); i < n; ++i)
    {
        auto const tracker = tr_torrentTracker(self.fHandle, i);

        if ([trackers containsObject:@(tracker.announce)])
        {
            continue;
        }

        if (current_tier && *current_tier != tracker.tier)
        {
            new_list += '\n';
        }

        new_list += tracker.announce;
        new_list += '\n';

        current_tier = tracker.tier;
    }

    BOOL const success = tr_torrentSetTrackerList(self.fHandle, new_list.c_str());
    NSAssert(success, @"Removing tracker addresses failed");
}

- (NSString*)comment
{
    auto const* comment = tr_torrentView(self.fHandle).comment;
    return comment ? @(comment) : @"";
}

- (NSURL*)commentURL
{
    NSString* comment = self.comment;
    if (comment.length == 0)
    {
        return nil;
    }
    NSDataDetector* detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    NSTextCheckingResult* result = [detector firstMatchInString:comment options:0 range:NSMakeRange(0, comment.length)];
    return result.URL;
}

- (NSString*)creator
{
    auto const* creator = tr_torrentView(self.fHandle).creator;
    return creator ? @(creator) : @"";
}

- (NSDate*)dateCreated
{
    auto const date = tr_torrentView(self.fHandle).date_created;
    return date > 0 ? [NSDate dateWithTimeIntervalSince1970:date] : nil;
}

- (NSInteger)pieceSize
{
    return tr_torrentView(self.fHandle).piece_size;
}

- (NSInteger)pieceCount
{
    return tr_torrentView(self.fHandle).n_pieces;
}

- (NSString*)hashString
{
    return @(tr_torrentView(self.fHandle).hash_string);
}

- (BOOL)privateTorrent
{
    return tr_torrentView(self.fHandle).is_private;
}

- (NSString*)torrentLocation
{
    return @(tr_torrentFilename(self.fHandle).c_str());
}

- (NSString*)dataLocation
{
    if (self.magnet)
    {
        return nil;
    }

    if (self.folder)
    {
        NSString* dataLocation = [self.currentDirectory stringByAppendingPathComponent:self.name];

        if (![NSFileManager.defaultManager fileExistsAtPath:dataLocation])
        {
            return nil;
        }

        return dataLocation;
    }
    else
    {
        auto const location = tr_torrentFindFile(self.fHandle, 0);
        return std::empty(location) ? nil : @(location.c_str());
    }
}

- (BOOL)allFilesMissing
{
    if (self.magnet || self.fileCount == 0)
    {
        return NO;
    }

    for (NSUInteger i = 0; i < self.fileCount; ++i)
    {
        if (!std::empty(tr_torrentFindFile(self.fHandle, i)))
        {
            return NO;
        }
    }

    return YES;
}

- (NSString*)lastKnownDataLocation
{
    if (self.magnet)
    {
        return nil;
    }

    if (self.folder)
    {
        NSString* lastDataLocation = [self.currentDirectory stringByAppendingPathComponent:self.name];
        return lastDataLocation;
    }
    else
    {
        auto const lastFileName = @(tr_torrentFile(self.fHandle, 0).name);
        return [self.currentDirectory stringByAppendingPathComponent:lastFileName];
    }
}

- (NSString*)fileLocation:(FileListNode*)node
{
    if (node.isFolder)
    {
        NSString* basePath = [node.path stringByAppendingPathComponent:node.name];
        NSString* dataLocation = [self.currentDirectory stringByAppendingPathComponent:basePath];

        if (![NSFileManager.defaultManager fileExistsAtPath:dataLocation])
        {
            return nil;
        }

        return dataLocation;
    }
    else
    {
        auto const location = tr_torrentFindFile(self.fHandle, node.indexes.firstIndex);
        return std::empty(location) ? nil : @(location.c_str());
    }
}

// Moved to Torrent+PathResolution.mm

- (NSString*)pathToOpenForFileNode:(FileListNode*)node
{
    NSString* path = [self fileLocation:node];
    if (!path)
        return nil;
    if (node.isFolder)
    {
        NSString* basePath = node.path.length > 0 ? [node.path stringByAppendingPathComponent:node.name] : node.name;
        NSString* pathToOpen = [self pathToOpenForFolder:basePath];
        return pathToOpen ?: path;
    }
    return [self pathToOpenForAudioPath:path];
}

- (NSString*)pathToOpenForPlayableItem:(NSDictionary*)item
{
    NSString* type = item[@"type"] ?: @"file";
    NSString* path = item[@"path"];
    if ([type isEqualToString:@"album"])
    {
        NSString* folder = item[@"folder"];
        if (folder.length > 0)
        {
            NSString* pathToOpen = [self pathToOpenForFolder:folder];
            if (pathToOpen)
                return pathToOpen;
        }
    }
    else if (path.length > 0)
    {
        NSString* ext = path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"djvu"] || [ext isEqualToString:@"djv"])
        {
            NSString* pdfPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
            if ([NSFileManager.defaultManager fileExistsAtPath:pdfPath])
                path = pdfPath;
        }
        return [self pathToOpenForAudioPath:path];
    }
    return path;
}

- (BOOL)iinaUnwatchedForVideoPath:(NSString*)path
{
    return [IINAWatchHelper unwatchedForVideoPath:path completionObject:self];
}

+ (void)invalidateIINAWatchCacheForPath:(NSString*)path
{
    [IINAWatchHelper invalidateCacheForPath:path];
}

- (void)renameTorrent:(NSString*)newName completionHandler:(void (^)(BOOL didRename))completionHandler
{
    NSParameterAssert(newName != nil);
    NSParameterAssert(![newName isEqualToString:@""]);

    NSDictionary* contextInfo = @{ @"Torrent" : self, @"CompletionHandler" : [completionHandler copy] };

    tr_torrentRenamePath(self.fHandle, tr_torrentName(self.fHandle), newName.UTF8String, renameCallback, (__bridge_retained void*)(contextInfo));
}

- (void)renameFileNode:(FileListNode*)node
              withName:(NSString*)newName
     completionHandler:(void (^)(BOOL didRename))completionHandler
{
    NSParameterAssert(node.torrent == self);
    NSParameterAssert(newName != nil);
    NSParameterAssert(![newName isEqualToString:@""]);

    NSDictionary* contextInfo = @{ @"Torrent" : self, @"Nodes" : @[ node ], @"CompletionHandler" : [completionHandler copy] };

    NSString* oldPath = [node.path stringByAppendingPathComponent:node.name];
    tr_torrentRenamePath(self.fHandle, oldPath.UTF8String, newName.UTF8String, renameCallback, (__bridge_retained void*)(contextInfo));
}

- (time_t)eta
{
    time_t eta = self.fStat->eta;
    if (eta >= 0)
    {
        return eta;
    }
    time_t etaIdle = self.fStat->etaIdle;
    if (etaIdle >= 0 && etaIdle < kETAIdleDisplaySec)
    {
        return etaIdle;
    }
    if (self.fStat->leftUntilDone <= 0)
    {
        // We return smallest amount of time remaining for simplest compliance with sorting.
        return 0;
    }
    // We return highest amount of time remaining for simplest compliance with sorting.
    return LONG_MAX;
}

- (CGFloat)progress
{
    return self.fStat->percentComplete;
}

- (CGFloat)progressDone
{
    return self.fStat->percentDone;
}

- (CGFloat)consecutiveProgress
{
    // Calculate weighted average consecutive progress across all files
    auto const fileCount = tr_torrentFileCount(self.fHandle);
    if (fileCount == 0)
    {
        return 1.0;
    }

    CGFloat totalProgress = 0;
    uint64_t totalSize = 0;

    for (tr_file_index_t i = 0; i < fileCount; ++i)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        totalProgress += [self fileProgressForIndex:i] * file.length;
        totalSize += file.length;
    }

    return (totalSize > 0) ? totalProgress / totalSize : 1.0;
}

- (CGFloat)progressLeft
{
    if (self.size == 0) //magnet links
    {
        return 0.0;
    }

    return (CGFloat)self.sizeLeft / self.size;
}

- (CGFloat)checkingProgress
{
    return self.fStat->recheckProgress;
}

- (CGFloat)availableDesired
{
    return (CGFloat)self.fStat->desiredAvailable / self.sizeLeft;
}

- (BOOL)isActive
{
    return self.fStat->activity != TR_STATUS_STOPPED && self.fStat->activity != TR_STATUS_DOWNLOAD_WAIT &&
        self.fStat->activity != TR_STATUS_SEED_WAIT;
}

- (BOOL)isTransmitting
{
    return self.fStat->peersGettingFromUs > 0 || self.fStat->peersSendingToUs > 0 || self.fStat->webseedsSendingToUs > 0 ||
        self.fStat->activity == TR_STATUS_CHECK;
}

- (BOOL)isSeeding
{
    return self.fStat->activity == TR_STATUS_SEED;
}

- (BOOL)isDownloading
{
    return self.fStat->activity == TR_STATUS_DOWNLOAD;
}

- (BOOL)isChecking
{
    return self.fStat->activity == TR_STATUS_CHECK || self.fStat->activity == TR_STATUS_CHECK_WAIT;
}

- (BOOL)isCheckingWaiting
{
    return self.fStat->activity == TR_STATUS_CHECK_WAIT;
}

- (BOOL)allDownloaded
{
    return self.sizeLeft == 0 && !self.magnet;
}

- (BOOL)isComplete
{
    return self.progress >= 1.0;
}

- (BOOL)isFinishedSeeding
{
    return self.fStat->finished;
}

- (BOOL)isPausedForDiskSpace
{
    return self.fPausedForDiskSpace;
}

- (uint64_t)diskSpaceNeeded
{
    return self.fDiskSpaceNeeded;
}

- (uint64_t)diskSpaceAvailable
{
    return self.fDiskSpaceAvailable;
}

- (uint64_t)diskSpaceTotal
{
    return self.fDiskSpaceTotal;
}

- (BOOL)isError
{
    return self.fStat->error == TR_STAT_LOCAL_ERROR;
}

- (BOOL)isAnyErrorOrWarning
{
    return self.fStat->error != TR_STAT_OK;
}

- (NSString*)errorMessage
{
    if (!self.anyErrorOrWarning)
    {
        return @"";
    }

    NSString* error;
    if (!(error = @(self.fStat->errorString)) &&
        !(error = [NSString stringWithCString:self.fStat->errorString encoding:NSISOLatin1StringEncoding]))
    {
        error = [NSString stringWithFormat:@"(%@)", NSLocalizedString(@"unreadable error", "Torrent -> error string unreadable")];
    }

    //libtransmission uses "Set Location", Mac client uses "Move data file to..." - very hacky!
    error = [error stringByReplacingOccurrencesOfString:@"Set Location" withString:[@"Move Data File To" stringByAppendingEllipsis]];

    return error;
}

- (NSArray<NSDictionary*>*)peers
{
    size_t totalPeers;
    tr_peer_stat* peers = tr_torrentPeers(self.fHandle, &totalPeers);

    NSMutableArray* peerDicts = [NSMutableArray arrayWithCapacity:totalPeers];

    for (size_t i = 0; i < totalPeers; i++)
    {
        tr_peer_stat* peer = &peers[i];
        NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithCapacity:12];

        dict[@"Name"] = self.name;
        dict[@"From"] = @(peer->from);
        dict[@"IP"] = @(peer->addr);
        dict[@"Port"] = @(peer->port);
        dict[@"Progress"] = @(peer->progress);
        dict[@"Seed"] = @(peer->isSeed);
        dict[@"Encryption"] = @(peer->isEncrypted);
        dict[@"uTP"] = @(peer->isUTP);
        dict[@"Client"] = @(peer->client);
        dict[@"Flags"] = @(peer->flagStr);

        if (peer->isUploadingTo)
        {
            dict[@"UL To Rate"] = @(peer->rateToPeer_KBps);
        }
        if (peer->isDownloadingFrom)
        {
            dict[@"DL From Rate"] = @(peer->rateToClient_KBps);
        }

        [peerDicts addObject:dict];
    }

    tr_torrentPeersFree(peers, totalPeers);

    return peerDicts;
}

- (NSUInteger)webSeedCount
{
    return tr_torrentWebseedCount(self.fHandle);
}

- (NSArray<NSDictionary*>*)webSeeds
{
    NSUInteger n = tr_torrentWebseedCount(self.fHandle);
    NSMutableArray* webSeeds = [NSMutableArray arrayWithCapacity:n];

    for (NSUInteger i = 0; i < n; ++i)
    {
        auto const webseed = tr_torrentWebseed(self.fHandle, i);
        NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithCapacity:3];

        dict[@"Name"] = self.name;
        dict[@"Address"] = @(webseed.url);

        if (webseed.is_downloading)
        {
            dict[@"DL From Rate"] = @(double(webseed.download_bytes_per_second) / 1000);
        }

        [webSeeds addObject:dict];
    }

    return webSeeds;
}

- (NSUInteger)statsGeneration
{
    return self.fStatsGeneration;
}

- (CGFloat)downloadRate
{
    return self.fStat->pieceDownloadSpeed_KBps;
}

- (CGFloat)uploadRate
{
    return self.fStat->pieceUploadSpeed_KBps;
}

- (CGFloat)totalRate
{
    return self.downloadRate + self.uploadRate;
}

- (uint64_t)haveVerified
{
    return self.fStat->haveValid;
}

- (uint64_t)haveTotal
{
    return self.haveVerified + self.fStat->haveUnchecked;
}

- (uint64_t)totalSizeSelected
{
    return self.fStat->sizeWhenDone;
}

- (uint64_t)downloadedTotal
{
    return self.fStat->downloadedEver;
}

- (uint64_t)uploadedTotal
{
    return self.fStat->uploadedEver;
}

- (uint64_t)failedHash
{
    return self.fStat->corruptEver;
}

- (void)setGroupValue:(NSInteger)groupValue determinationType:(TorrentDeterminationType)determinationType
{
    if (groupValue != self.groupValue)
    {
        self.groupValue = groupValue;
        [NSNotificationCenter.defaultCenter postNotificationName:kTorrentDidChangeGroupNotification object:self];
    }
    self.fGroupValueDetermination = determinationType;
}

- (NSInteger)groupOrderValue
{
    return [GroupsController.groups rowValueForIndex:self.groupValue];
}

- (void)checkGroupValueForRemoval:(NSNotification*)notification
{
    if (self.groupValue != -1 && [notification.userInfo[@"Index"] integerValue] == self.groupValue)
    {
        self.groupValue = -1;
    }
}

- (void)handleConversionCompleteForTorrentHash:(NSString*)torrentHash
{
    // Safety check: don't access fHandle if torrent is being deallocated
    if (!self.fHandle)
        return;

    // Only invalidate cache if this notification is for our torrent
    if ([torrentHash isEqualToString:self.hashString])
    {
        // Invalidate playable files cache so companion files are detected
        self.fPlayableFiles = nil;
        // Also invalidate cached button state
        self.cachedPlayButtonState = nil;
        self.cachedPlayButtonSource = nil;
        self.cachedPlayButtonLayout = nil;

        // Trigger UI refresh
        [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateUI" object:nil];
    }
}

- (void)djvuConversionComplete:(NSNotification*)notification
{
    [self handleConversionCompleteForTorrentHash:notification.object];
}

- (void)fb2ConversionComplete:(NSNotification*)notification
{
    [self handleConversionCompleteForTorrentHash:notification.object];
}

- (NSUInteger)fileCount
{
    return tr_torrentFileCount(self.fHandle);
}

- (CGFloat)fileProgress:(FileListNode*)node
{
    if (self.fileCount == 1 || self.complete)
    {
        return self.progress;
    }

    // #5501
    if (node.size == 0)
    {
        return 1.0;
    }

    uint64_t have = 0;
    NSIndexSet* indexSet = node.indexes;
    for (NSInteger index = indexSet.firstIndex; index != NSNotFound; index = [indexSet indexGreaterThanIndex:index])
    {
        have += tr_torrentFile(self.fHandle, index).have;
    }

    return (CGFloat)have / node.size;
}

- (BOOL)canChangeDownloadCheckForFile:(NSUInteger)index
{
    NSAssert2(index < self.fileCount, @"Index %lu is greater than file count %lu", index, self.fileCount);

    return [self canChangeDownloadCheckForFiles:[NSIndexSet indexSetWithIndex:index]];
}

- (BOOL)canChangeDownloadCheckForFiles:(NSIndexSet*)indexSet
{
    if (self.fileCount == 1 || self.complete)
    {
        return NO;
    }

    __block BOOL canChange = NO;
    [indexSet enumerateIndexesWithOptions:NSEnumerationConcurrent usingBlock:^(NSUInteger index, BOOL* stop) {
        auto const file = tr_torrentFile(self.fHandle, index);
        if (file.have < file.length)
        {
            canChange = YES;
            *stop = YES;
        }
    }];
    return canChange;
}

- (NSControlStateValue)checkForFiles:(NSIndexSet*)indexSet
{
    BOOL onState = NO, offState = NO;
    for (NSUInteger index = indexSet.firstIndex; index != NSNotFound; index = [indexSet indexGreaterThanIndex:index])
    {
        auto const file = tr_torrentFile(self.fHandle, index);
        if (file.wanted || ![self canChangeDownloadCheckForFile:index])
        {
            onState = YES;
        }
        else
        {
            offState = YES;
        }

        if (onState && offState)
        {
            return NSControlStateValueMixed;
        }
    }
    return onState ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setFileCheckState:(NSControlStateValue)state forIndexes:(NSIndexSet*)indexSet
{
    NSUInteger count = indexSet.count;
    tr_file_index_t* files = static_cast<tr_file_index_t*>(malloc(count * sizeof(tr_file_index_t)));
    [indexSet getIndexes:files maxCount:count inIndexRange:nil];

    tr_torrentSetFileDLs(self.fHandle, files, count, state != NSControlStateValueOff);
    free(files);

    self.fPlayableFiles = nil;
    self.cachedPlayButtonState = nil;
    self.cachedPlayButtonSource = nil;
    self.cachedPlayButtonLayout = nil;

    [self update];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TorrentFileCheckChange" object:self];
}

- (void)setFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet*)indexSet
{
    NSUInteger const count = indexSet.count;
    auto files = std::vector<tr_file_index_t>{};
    files.resize(count);
    for (NSUInteger index = indexSet.firstIndex, i = 0; index != NSNotFound; index = [indexSet indexGreaterThanIndex:index], i++)
    {
        files[i] = index;
    }

    tr_torrentSetFilePriorities(self.fHandle, std::data(files), std::size(files), priority);
}

- (BOOL)hasFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet*)indexSet
{
    for (NSUInteger index = indexSet.firstIndex; index != NSNotFound; index = [indexSet indexGreaterThanIndex:index])
    {
        if (priority == tr_torrentFile(self.fHandle, index).priority && [self canChangeDownloadCheckForFile:index])
        {
            return YES;
        }
    }
    return NO;
}

- (NSSet*)filePrioritiesForIndexes:(NSIndexSet*)indexSet
{
    BOOL low = NO, normal = NO, high = NO;
    NSMutableSet* priorities = [NSMutableSet setWithCapacity:MIN(indexSet.count, 3u)];

    for (NSUInteger index = indexSet.firstIndex; index != NSNotFound; index = [indexSet indexGreaterThanIndex:index])
    {
        if (![self canChangeDownloadCheckForFile:index])
        {
            continue;
        }

        auto const priority = tr_torrentFile(self.fHandle, index).priority;
        switch (priority)
        {
        case TR_PRI_LOW:
            if (low)
            {
                continue;
            }
            low = YES;
            break;
        case TR_PRI_NORMAL:
            if (normal)
            {
                continue;
            }
            normal = YES;
            break;
        case TR_PRI_HIGH:
            if (high)
            {
                continue;
            }
            high = YES;
            break;
        default:
            NSAssert2(NO, @"Unknown priority %d for file index %ld", priority, index);
        }

        [priorities addObject:@(priority)];
        if (low && normal && high)
        {
            break;
        }
    }
    return priorities;
}

- (NSDate*)dateAdded
{
    time_t const date = self.fStat->addedDate;
    return [NSDate dateWithTimeIntervalSince1970:date];
}

- (NSDate*)dateCompleted
{
    time_t const date = self.fStat->doneDate;
    return date != 0 ? [NSDate dateWithTimeIntervalSince1970:date] : nil;
}

- (NSDate*)dateActivity
{
    time_t const date = self.fStat->activityDate;
    return date != 0 ? [NSDate dateWithTimeIntervalSince1970:date] : nil;
}

- (NSDate*)dateActivityOrAdd
{
    NSDate* date = self.dateActivity;
    return date ? date : self.dateAdded;
}

- (NSDate*)dateLastPlayed
{
    time_t const date = self.fStat->lastPlayedDate;
    return date != 0 ? [NSDate dateWithTimeIntervalSince1970:date] : nil;
}

- (NSInteger)secondsDownloading
{
    return self.fStat->secondsDownloading;
}

- (NSInteger)secondsSeeding
{
    return self.fStat->secondsSeeding;
}

- (NSInteger)stalledMinutes
{
    if (self.fStat->idleSecs == -1)
    {
        return -1;
    }

    return self.fStat->idleSecs / 60;
}

- (BOOL)isStalled
{
    return self.fStat->isStalled;
}

- (void)updateTimeMachineExclude
{
    [self setTimeMachineExclude:!self.allDownloaded];
}

- (NSInteger)stateSortKey
{
    if (!self.active) //paused
    {
        if (self.waitingToStart)
        {
            return 1;
        }
        else
        {
            return 0;
        }
    }
    else if (self.seeding) //seeding
    {
        return 10;
    }
    else //downloading
    {
        return 20;
    }
}

- (NSString*)trackerSortKey
{
    NSString* best = nil;

    for (size_t i = 0, n = tr_torrentTrackerCount(self.fHandle); i < n; ++i)
    {
        auto const tracker = tr_torrentTracker(self.fHandle, i);

        NSString* host_and_port = @(tracker.host_and_port);
        if (!best || [host_and_port localizedCaseInsensitiveCompare:best] == NSOrderedAscending)
        {
            best = host_and_port;
        }
    }

    return best;
}

- (tr_torrent*)torrentStruct
{
    return self.fHandle;
}

- (NSURL*)previewItemURL
{
    NSString* location = self.dataLocation;
    return location ? [NSURL fileURLWithPath:location] : nil;
}

#pragma mark - Private

- (instancetype)initWithPath:(NSString*)path
                        hash:(NSString*)hashString
               torrentStruct:(tr_torrent*)torrentStruct
               magnetAddress:(NSString*)magnetAddress
                         lib:(tr_session*)lib
                  groupValue:(NSNumber*)groupValue
     removeWhenFinishSeeding:(NSNumber*)removeWhenFinishSeeding
              downloadFolder:(NSString*)downloadFolder
      legacyIncompleteFolder:(NSString*)incompleteFolder
{
    if (!(self = [super init]))
    {
        return nil;
    }

    _fDefaults = NSUserDefaults.standardUserDefaults;

    if (torrentStruct)
    {
        _fHandle = torrentStruct;
        _fSession = lib;
    }
    else
    {
        //set libtransmission settings for initialization
        tr_ctor* ctor = tr_ctorNew(lib);

        tr_ctorSetPaused(ctor, TR_FORCE, YES);
        if (downloadFolder)
        {
            tr_ctorSetDownloadDir(ctor, TR_FORCE, downloadFolder.UTF8String);
        }
        if (incompleteFolder)
        {
            tr_ctorSetIncompleteDir(ctor, incompleteFolder.UTF8String);
        }

        bool loaded = false;

        if (path)
        {
            loaded = tr_ctorSetMetainfoFromFile(ctor, path.UTF8String, nullptr);
        }

        if (!loaded && magnetAddress)
        {
            loaded = tr_ctorSetMetainfoFromMagnetLink(ctor, magnetAddress.UTF8String, nullptr);
        }

        if (loaded)
        {
            _fHandle = tr_torrentNew(ctor, NULL);
            _fSession = lib;
        }

        tr_ctorFree(ctor);

        if (!_fHandle)
        {
            return nil;
        }
    }

    _fResumeOnWake = NO;
    _fDiskSpaceDialogShown = NO;

    //don't do after this point - it messes with auto-group functionality
    if (!self.magnet)
    {
        [self createFileList];
    }

    _fDownloadFolderDetermination = TorrentDeterminationAutomatic;

    _playedFiles = [[NSMutableIndexSet alloc] init];

    if (groupValue)
    {
        _fGroupValueDetermination = TorrentDeterminationUserSpecified;
        _groupValue = groupValue.intValue;
    }
    else
    {
        _fGroupValueDetermination = TorrentDeterminationAutomatic;
        _groupValue = [GroupsController.groups groupIndexForTorrent:self];
    }

    _removeWhenFinishSeeding = removeWhenFinishSeeding ? removeWhenFinishSeeding.boolValue :
                                                         [_fDefaults boolForKey:@"RemoveWhenFinishSeeding"];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(checkGroupValueForRemoval:)
                                               name:@"GroupValueRemoved"
                                             object:nil];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(djvuConversionComplete:)
                                               name:@"DjvuConversionComplete"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fb2ConversionComplete:)
                                               name:@"Fb2ConversionComplete"
                                             object:nil];

    [self update];
    [self updateTimeMachineExclude];

    return self;
}

- (void)completenessChange:(tr_completeness)status wasRunning:(BOOL)wasRunning
{
    self.fStat = tr_torrentStat(self.fHandle); //don't call update yet to avoid auto-stop

    switch (status)
    {
    case TR_SEED:
    case TR_PARTIAL_SEED:
        {
            // Invalidate icon cache so it refreshes with actual file icon (e.g., PDF preview)
            self.fIcon = nil;

            NSDictionary* statusInfo = @{@"Status" : @(status), @"WasRunning" : @(wasRunning)};
            [NSNotificationCenter.defaultCenter postNotificationName:@"TorrentFinishedDownloading" object:self userInfo:statusInfo];

            //quarantine the finished data
            NSString* dataLocation = [self.currentDirectory stringByAppendingPathComponent:self.name];
            NSURL* dataLocationUrl = [NSURL fileURLWithPath:dataLocation];
            NSDictionary* quarantineProperties = @{
                (NSString*)kLSQuarantineTypeKey : (NSString*)kLSQuarantineTypeOtherDownload
            };
            NSError* error = nil;
            if (![dataLocationUrl setResourceValue:quarantineProperties forKey:NSURLQuarantinePropertiesKey error:&error])
            {
                NSLog(@"Failed to quarantine %@: %@", dataLocation, error.description);
            }
            break;
        }
    case TR_LEECH:
        [NSNotificationCenter.defaultCenter postNotificationName:@"TorrentRestartedDownloading" object:self];
        break;
    }

    [self update];
    [self updateTimeMachineExclude];
}

- (void)ratioLimitHit
{
    self.fStat = tr_torrentStat(self.fHandle);

    [NSNotificationCenter.defaultCenter postNotificationName:@"TorrentFinishedSeeding" object:self];
}

- (void)idleLimitHit
{
    self.fStat = tr_torrentStat(self.fHandle);

    [NSNotificationCenter.defaultCenter postNotificationName:@"TorrentFinishedSeeding" object:self];
}

- (void)metadataRetrieved
{
    self.fStat = tr_torrentStat(self.fHandle);

    [self createFileList];

    // Reset media type detection and playable files cache since we now have metadata
    self.fMediaTypeDetected = NO;
    self.fPlayableFiles = nil;
    self.fFolderToFiles = nil;
    self.fFileProgressCache = nil;
    self.fFolderProgressCache = nil;
    self.fFolderFirstMediaProgressCache = nil;

    /* If the torrent is in no group, or the group was automatically determined based on criteria evaluated
     * before we had metadata for this torrent, redetermine the group
     */
    if ((self.fGroupValueDetermination == TorrentDeterminationAutomatic) || (self.groupValue == -1))
    {
        [self setGroupValue:[GroupsController.groups groupIndexForTorrent:self] determinationType:TorrentDeterminationAutomatic];
    }

    //change the location if the group calls for it and it's either not already set or was set automatically before
    if (((self.fDownloadFolderDetermination == TorrentDeterminationAutomatic) || !tr_torrentGetCurrentDir(self.fHandle)) &&
        [GroupsController.groups usesCustomDownloadLocationForIndex:self.groupValue])
    {
        NSString* location = [GroupsController.groups customDownloadLocationForIndex:self.groupValue];
        [self changeDownloadFolderBeforeUsing:location determinationType:TorrentDeterminationAutomatic];
    }

    [NSNotificationCenter.defaultCenter postNotificationName:@"ResetInspector" object:self userInfo:@{ @"Torrent" : self }];
}

- (void)renameFinished:(BOOL)success
                 nodes:(NSArray<FileListNode*>*)nodes
     completionHandler:(void (^)(BOOL))completionHandler
               oldPath:(NSString*)oldPath
               newName:(NSString*)newName
{
    NSParameterAssert(completionHandler != nil);
    NSParameterAssert(oldPath != nil);
    NSParameterAssert(newName != nil);

    NSString* path = oldPath.stringByDeletingLastPathComponent;

    if (success)
    {
        NSString* oldName = oldPath.lastPathComponent;

        using UpdateNodeAndChildrenForRename = void (^)(FileListNode*);
        __weak __block UpdateNodeAndChildrenForRename weakUpdateNodeAndChildrenForRename;
        UpdateNodeAndChildrenForRename updateNodeAndChildrenForRename;
        weakUpdateNodeAndChildrenForRename = updateNodeAndChildrenForRename = ^(FileListNode* node) {
            [node updateFromOldName:oldName toNewName:newName inPath:path];

            if (node.isFolder)
            {
                [node.children enumerateObjectsWithOptions:NSEnumerationConcurrent
                                                usingBlock:^(FileListNode* childNode, NSUInteger /*idx*/, BOOL* /*stop*/) {
                                                    weakUpdateNodeAndChildrenForRename(childNode);
                                                }];
            }
        };

        if (!nodes)
        {
            nodes = self.flatFileList;
        }
        [nodes enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(FileListNode* node, NSUInteger /*idx*/, BOOL* /*stop*/) {
            updateNodeAndChildrenForRename(node);
        }];

        //resort lists
        NSMutableArray* fileList = [self.fileList mutableCopy];
        [self sortFileList:fileList];
        self.fileList = fileList;

        NSMutableArray* flatFileList = [self.flatFileList mutableCopy];
        [self sortFileList:flatFileList];
        self.flatFileList = flatFileList;

        self.fIcon = nil;
        self.fDisplayName = nil;
    }
    else
    {
        NSLog(@"Error renaming %@ to %@", oldPath, [path stringByAppendingPathComponent:newName]);
    }

    completionHandler(success);
}

- (void)setTimeMachineExclude:(BOOL)exclude
{
    NSString* path;
    if ((path = self.dataLocation))
    {
        dispatch_async(timeMachineExcludeQueue, ^{
            CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
            CSBackupSetItemExcluded(url, exclude, false);
        });
    }
}

// For backward compatibility for previously saved Group Predicates.
- (NSArray<FileListNode*>*)fFlatFileList
{
    return self.flatFileList;
}

#pragma clang diagnostic pop
@end
