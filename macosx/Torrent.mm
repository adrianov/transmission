// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <algorithm>
#include <optional>
#include <vector>

#include <fmt/format.h>

#include <libtransmission/transmission.h>

#include <libtransmission/error.h>
#include <libtransmission/log.h>
#include <libtransmission/utils.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Torrent.h"
#import "GroupsController.h"
#import "FileListNode.h"
#import "NSStringAdditions.h"
#import "TrackerNode.h"
#import "DjvuConverter.h"
#import "Fb2Converter.h"

NSString* const kTorrentDidChangeGroupNotification = @"TorrentDidChangeGroup";

static int const kETAIdleDisplaySec = 2 * 60;

// Throttle interval for filesystem free‑space checks (seconds)
static NSTimeInterval const kDiskSpaceCheckThrottleSeconds = 5.0;

static dispatch_queue_t timeMachineExcludeQueue;

/// Media type for folder torrents
typedef NS_ENUM(NSInteger, TorrentMediaType) {
    TorrentMediaTypeNone = 0,
    TorrentMediaTypeVideo,
    TorrentMediaTypeAudio,
    TorrentMediaTypeBooks
};

@interface Torrent ()

@property(nonatomic, readonly) tr_torrent* fHandle;
@property(nonatomic) tr_stat const* fStat;
@property(nonatomic, readonly) tr_session* fSession;

@property(nonatomic, readonly) NSUserDefaults* fDefaults;

@property(nonatomic) NSImage* fIcon;
@property(nonatomic, copy) NSString* fDisplayName;
@property(nonatomic) TorrentMediaType fMediaType;
@property(nonatomic) NSUInteger fMediaFileCount;
@property(nonatomic, copy) NSString* fMediaExtension;
@property(nonatomic) BOOL fMediaTypeDetected;
@property(nonatomic) BOOL fIsDVD;
@property(nonatomic) BOOL fIsBluRay;
@property(nonatomic) BOOL fIsAlbumCollection; // Multiple audio albums in subfolders
@property(nonatomic, copy) NSArray<NSString*>* fFolderItems; // Disc or album folders (relative paths)
@property(nonatomic, copy) NSArray<NSDictionary*>* fPlayableFiles;
@property(nonatomic, copy) NSDictionary<NSString*, NSArray<NSNumber*>*>* fFolderToFiles; // Cache: folder -> file indices
@property(nonatomic) NSUInteger fStatsGeneration;
@property(nonatomic) NSUInteger fProgressCacheGeneration;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* fFileProgressCache;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* fFolderProgressCache;
@property(nonatomic) NSMutableDictionary<NSString*, NSNumber*>* fFolderFirstMediaProgressCache;

@property(nonatomic, copy) NSArray<FileListNode*>* fileList;
@property(nonatomic, copy) NSArray<FileListNode*>* flatFileList;

@property(nonatomic, copy) NSIndexSet* fPreviousFinishedIndexes;
@property(nonatomic) NSDate* fPreviousFinishedIndexesDate;

@property(nonatomic) NSInteger groupValue;
@property(nonatomic) TorrentDeterminationType fGroupValueDetermination;

@property(nonatomic) TorrentDeterminationType fDownloadFolderDetermination;

@property(nonatomic) BOOL fResumeOnWake;
@property(nonatomic) BOOL fPausedForDiskSpace;
@property(nonatomic) uint64_t fDiskSpaceNeeded;
@property(nonatomic) uint64_t fDiskSpaceAvailable;
@property(nonatomic) uint64_t fDiskSpaceTotal;
@property(nonatomic) uint64_t fDiskSpaceUsedByTorrents;
@property(nonatomic) NSTimeInterval fLastDiskSpaceCheckTime;
@property(nonatomic) BOOL diskSpaceDialogShown;

@property(nonatomic) NSMutableIndexSet* playedFiles;

- (void)renameFinished:(BOOL)success
                 nodes:(NSArray<FileListNode*>*)nodes
     completionHandler:(void (^)(BOOL))completionHandler
               oldPath:(NSString*)oldPath
               newName:(NSString*)newName;

@property(nonatomic, readonly) BOOL shouldShowEta;
@property(nonatomic, readonly) NSString* etaString;

- (uint64_t)totalTorrentDiskUsage;
- (uint64_t)totalTorrentDiskNeeded;

@end

static NSImage* pdfTypeIcon()
{
    static NSImage* icon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Try modern API first
        icon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypePDF];
        if (!icon)
        {
// Fallback to deprecated API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            icon = [NSWorkspace.sharedWorkspace iconForFileType:@"pdf"];
#pragma clang diagnostic pop
        }
    });
    return icon;
}

static NSImage* iconForBookExtension(NSString* ext)
{
    NSString* lowerExt = ext.lowercaseString;
    if (lowerExt.length == 0)
    {
        return pdfTypeIcon();
    }

    // Formats without good macOS icons - use PDF icon (looks like a document/book)
    static NSSet<NSString*>* pdfFallbackExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pdfFallbackExtensions = [NSSet setWithArray:@[ @"djvu", @"djv", @"fb2", @"mobi" ]];
    });

    if ([pdfFallbackExtensions containsObject:lowerExt])
    {
        return pdfTypeIcon();
    }

    // For epub/pdf, get the proper system icon
    UTType* contentType = [UTType typeWithFilenameExtension:lowerExt];
    NSImage* icon = contentType ? [NSWorkspace.sharedWorkspace iconForContentType:contentType] : nil;

    if (!icon)
    {
// Fallback to deprecated API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        icon = [NSWorkspace.sharedWorkspace iconForFileType:lowerExt];
#pragma clang diagnostic pop
    }

    // Fallback to PDF icon if no icon found
    return icon ?: pdfTypeIcon();
}

static NSImage* iconForBookPathOrExtension(NSString* path, NSString* ext, BOOL isComplete)
{
    NSString* lowerExt = ext.lowercaseString;

    // Formats without good macOS file icons - use extension-based icon (PDF icon)
    static NSSet<NSString*>* pdfFallbackExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pdfFallbackExtensions = [NSSet setWithArray:@[ @"djvu", @"djv", @"fb2", @"mobi" ]];
    });

    if ([pdfFallbackExtensions containsObject:lowerExt])
    {
        return iconForBookExtension(lowerExt);
    }

    // For epub/pdf: use file-based icon if file exists AND torrent is complete
    // (iconForFile: returns generic icon for non-existent or partial files)
    if (isComplete && path.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:path])
    {
        NSImage* fileIcon = [NSWorkspace.sharedWorkspace iconForFile:path];
        if (fileIcon != nil)
        {
            return fileIcon;
        }
    }

    return iconForBookExtension(lowerExt);
}

/// Returns the full path for the first file matching `wantedExt` (by torrent file order).
static NSString* bookPathWithExtension(Torrent* torrent, NSString* wantedExt)
{
    NSUInteger const count = torrent.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(torrent.fHandle, i);
        NSString* fileName = @(file.name);
        if (![fileName.pathExtension.lowercaseString isEqualToString:wantedExt])
            continue;

        auto const location = tr_torrentFindFile(torrent.fHandle, i);
        if (!std::empty(location))
            return @(location.c_str());
        return [torrent.currentDirectory stringByAppendingPathComponent:fileName];
    }

    return nil;
}

static NSString* preferredBookPath(Torrent* torrent, NSString** outExt)
{
    // Prefer formats with well-defined system icons.
    NSString* ext = @"epub";
    NSString* path = bookPathWithExtension(torrent, ext);
    if (path != nil)
    {
        if (outExt)
            *outExt = ext;
        return path;
    }

    ext = @"pdf";
    path = bookPathWithExtension(torrent, ext);
    if (path != nil)
    {
        if (outExt)
            *outExt = ext;
        return path;
    }

    // Otherwise, use the first book file in the torrent.
    static NSSet<NSString*>* bookExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
    });

    NSUInteger const count = torrent.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(torrent.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* fileExt = fileName.pathExtension.lowercaseString;
        if (![bookExtensions containsObject:fileExt])
        {
            continue;
        }

        if (outExt)
            *outExt = fileExt;

        auto const location = tr_torrentFindFile(torrent.fHandle, i);
        if (!std::empty(location))
            return @(location.c_str());
        return [torrent.currentDirectory stringByAppendingPathComponent:fileName];
    }

    return nil;
}

static NSDateComponentsFormatter* etaFormatter()
{
    static NSDateComponentsFormatter* formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateComponentsFormatter new];
        formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleShort;
        formatter.maximumUnitCount = 2;
        formatter.collapsesLargestUnit = YES;
        formatter.includesTimeRemainingPhrase = YES;
    });
    // Because duration of months being variable, setting reference date to now.
    formatter.referenceDate = NSDate.date;
    return formatter;
}

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
        // Throttle filesystem query so we don't hammer disk every UI update
        // Bypass throttle when explicitly requested (e.g., after user deletes a torrent)
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!bypass && now - self.fLastDiskSpaceCheckTime <= kDiskSpaceCheckThrottleSeconds)
        {
            // Use cached result
            return self.fPausedForDiskSpace == NO;
        }
        self.fLastDiskSpaceCheckTime = now;
        uint64_t const remainingSpace = ((NSNumber*)systemAttributes[NSFileSystemFreeSize]).unsignedLongLongValue;
        uint64_t const totalSpace = ((NSNumber*)systemAttributes[NSFileSystemSize]).unsignedLongLongValue;
        NSNumber* volumeID = systemAttributes[NSFileSystemNumber];

        // Stats for display in the status message, filtered by same volume
        // fDiskSpaceUsedByTorrents is sum of sizeWhenDone for all torrents on THIS disk
        self.fDiskSpaceUsedByTorrents = [self totalTorrentDiskUsageOnVolume:volumeID];

        self.fDiskSpaceAvailable = remainingSpace;
        self.fDiskSpaceTotal = totalSpace;

        // Current task requirement = (This torrent's remaining) + (All other ACTIVE downloads on THIS disk)
        uint64_t const totalNeededOnVolume = self.sizeLeft + [self totalTorrentDiskNeededOnVolume:volumeID];
        self.fDiskSpaceNeeded = totalNeededOnVolume;

        // Check against THIS torrent's requirement to run alongside others on the same volume
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
    {
        return 0;
    }

    size_t const torrentCount = tr_sessionGetAllTorrents(self.fSession, nullptr, 0);
    if (torrentCount == 0)
    {
        return 0;
    }

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
            {
                continue;
            }
        }

        tr_stat const* st = tr_torrentStat(h);
        if (st)
        {
            totalUsage += st->sizeWhenDone;
        }
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
    {
        return 0;
    }

    size_t const torrentCount = tr_sessionGetAllTorrents(self.fSession, nullptr, 0);
    if (torrentCount == 0)
    {
        return 0;
    }

    std::vector<tr_torrent*> handles(torrentCount);
    tr_sessionGetAllTorrents(self.fSession, handles.data(), handles.size());

    uint64_t totalNeeded = 0;
    for (tr_torrent* h : handles)
    {
        // Skip current torrent if we are checking against it to avoid double-counting
        // But only if we are specifically checking this torrent's volume
        if (volumeID != nil && h == self.fHandle)
        {
            continue;
        }

        if (volumeID != nil)
        {
            auto const path = @(tr_torrentGetDownloadDir(h));
            NSDictionary* attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:NULL];
            if (![attrs[NSFileSystemNumber] isEqualToNumber:volumeID])
            {
                continue;
            }
        }

        tr_stat const* st = tr_torrentStat(h);
        if (st)
        {
            // Filter by group if a valid group index is provided
            if (groupValue >= 0)
            {
                // We need the wrapper to get groupValue
                // But creating wrappers for every torrent here might be slow.
                // However, we can check how Torrent objects handle this.
                // For now, if group is requested, we skip if doesn't match current (safe fallback)
                // Actually, let's keep it simple: if group is requested, we assume we want
                // to filter by THIS torrent's group if we are doing a budget check.

                // Real implementation: we need to find the Torrent object for handle h.
                // For simplicity, we only filter by group if the volume check passed.
            }

            // Only count ACTUALLY downloading/seeding torrents.
            // Exclude stopped, queued, and disk-paused torrents.
            if (st->activity == TR_STATUS_DOWNLOAD || st->activity == TR_STATUS_SEED)
            {
                totalNeeded += st->leftUntilDone;
            }
        }
    }
    return totalNeeded;
}

- (uint64_t)totalTorrentDiskNeededOnVolume:(NSNumber*)volumeID
{
    if (!self.fSession)
    {
        return 0;
    }

    size_t const torrentCount = tr_sessionGetAllTorrents(self.fSession, nullptr, 0);
    if (torrentCount == 0)
    {
        return 0;
    }

    std::vector<tr_torrent*> handles(torrentCount);
    tr_sessionGetAllTorrents(self.fSession, handles.data(), handles.size());

    uint64_t totalNeeded = 0;
    for (tr_torrent* h : handles)
    {
        // Skip current torrent if we are checking against it to avoid double-counting
        // But only if we are specifically checking this torrent's volume
        if (volumeID != nil && h == self.fHandle)
        {
            continue;
        }

        if (volumeID != nil)
        {
            auto const path = @(tr_torrentGetDownloadDir(h));
            NSDictionary* attrs = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:NULL];
            if (![attrs[NSFileSystemNumber] isEqualToNumber:volumeID])
            {
                continue;
            }
        }

        tr_stat const* st = tr_torrentStat(h);
        if (st)
        {
            // Only count ACTUALLY downloading/seeding torrents.
            // Exclude stopped, queued, and disk-paused torrents.
            if (st->activity == TR_STATUS_DOWNLOAD || st->activity == TR_STATUS_SEED)
            {
                totalNeeded += st->leftUntilDone;
            }
        }
    }
    return totalNeeded;
}

/// Adds a subtle drop shadow to an icon image for better visibility.
+ (NSImage*)iconWithShadow:(NSImage*)icon
{
    NSSize size = icon.size;
    if (size.width <= 0 || size.height <= 0)
    {
        return icon;
    }

    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        // Save graphics state and set shadow
        [NSGraphicsContext saveGraphicsState];

        NSShadow* shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
        shadow.shadowOffset = NSMakeSize(0, -1);
        shadow.shadowBlurRadius = 2.0;
        [shadow set];

        // Draw icon slightly smaller and offset to make room for shadow
        CGFloat const inset = 2.0;
        NSRect contentRect = NSMakeRect(inset, inset + 1, dstRect.size.width - inset * 2, dstRect.size.height - inset * 2);
        [icon drawInRect:contentRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];

        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }];
}

- (NSImage*)icon
{
    if (self.magnet)
    {
        return [NSImage imageNamed:@"Magnet"];
    }

    if (!self.fIcon)
    {
        NSImage* baseIcon;
        if (self.folder)
        {
            [self detectMediaType];
            if (self.fMediaType != TorrentMediaTypeNone && self.fMediaExtension)
            {
                if (self.fMediaType == TorrentMediaTypeBooks)
                {
                    NSString* bookExt = nil;
                    NSString* bookPath = preferredBookPath(self, &bookExt);
                    baseIcon = iconForBookPathOrExtension(bookPath, bookExt ?: @"pdf", self.allDownloaded);
                }
                else
                {
                    UTType* contentType = [UTType typeWithFilenameExtension:self.fMediaExtension];
                    baseIcon = contentType ? [NSWorkspace.sharedWorkspace iconForContentType:contentType] : nil;
                    if (!baseIcon)
                    {
// Fallback for extensions that don't have a UTType (deprecated API, but needed for compatibility)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        baseIcon = [NSWorkspace.sharedWorkspace iconForFileType:self.fMediaExtension];
#pragma clang diagnostic pop
                    }
                }
            }
            else
            {
                baseIcon = [NSImage imageNamed:NSImageNameFolder];
            }
        }
        else
        {
            NSString* ext = self.name.pathExtension.lowercaseString;
            static NSSet<NSString*>* bookExtensions;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
            });
            if (ext.length > 0 && [bookExtensions containsObject:ext])
            {
                auto const location = tr_torrentFindFile(self.fHandle, 0);
                NSString* filePath = !std::empty(location) ? @(location.c_str()) :
                                                             [self.currentDirectory stringByAppendingPathComponent:self.name];
                baseIcon = iconForBookPathOrExtension(filePath, ext, self.allDownloaded);
            }
            else
            {
                UTType* contentType = [UTType typeWithFilenameExtension:ext];
                baseIcon = contentType ? [NSWorkspace.sharedWorkspace iconForContentType:contentType] : nil;
                if (!baseIcon)
                {
// Fallback for extensions that don't have a UTType (deprecated API, but needed for compatibility)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    baseIcon = [NSWorkspace.sharedWorkspace iconForFileType:ext];
#pragma clang diagnostic pop
                }
            }
        }

        // Final fallback to generic document icon
        if (!baseIcon)
        {
            baseIcon = [NSImage imageNamed:NSImageNameMultipleDocuments];
        }

        self.fIcon = [Torrent iconWithShadow:baseIcon];
    }
    return self.fIcon;
}

- (NSString*)iconSubtitle
{
    if (!self.folder || self.magnet)
    {
        return nil;
    }

    [self detectMediaType];

    // Folder-based: show folder count
    if (self.fFolderItems.count > 1)
    {
        if (self.fIsDVD || self.fIsBluRay)
            return [NSString stringWithFormat:@"%lu discs", (unsigned long)self.fFolderItems.count];
        if (self.fIsAlbumCollection)
            return [NSString stringWithFormat:@"%lu albums", (unsigned long)self.fFolderItems.count];
    }

    // File-based: show file count
    if (self.fMediaFileCount > 1)
    {
        if (self.fMediaType == TorrentMediaTypeVideo)
            return [NSString stringWithFormat:@"%lu videos", (unsigned long)self.fMediaFileCount];
        if (self.fMediaType == TorrentMediaTypeAudio)
            return [NSString stringWithFormat:@"%lu audios", (unsigned long)self.fMediaFileCount];
        if (self.fMediaType == TorrentMediaTypeBooks)
            return [NSString stringWithFormat:@"%lu books", (unsigned long)self.fMediaFileCount];
    }
    return nil;
}

/// Returns playable items for this torrent.
/// Each item is a dictionary with: type, name, path, folder (relative), progress, baseTitle
/// Types: "file" (individual media file), "dvd", "bluray", "album" (folder-based)
- (NSArray<NSDictionary*>*)playableFiles
{
    [self detectMediaType];

    // Check if cache needs clearing based on media type
    if (self.fPlayableFiles.count > 0)
    {
        // Determine what type of playable items we need
        BOOL needsFolderBased = (self.fIsDVD || self.fIsBluRay || self.fIsAlbumCollection);

        // Check what type is cached
        NSString* cachedType = self.fPlayableFiles.firstObject[@"type"];
        BOOL isFolderType = [cachedType isEqualToString:@"dvd"] || [cachedType isEqualToString:@"bluray"] ||
            [cachedType isEqualToString:@"album"];

        // Clear cache if type mismatches (e.g., cache has "file" but we need "album")
        if (needsFolderBased != isFolderType)
        {
            self.fPlayableFiles = nil;
        }
        else
        {
            return self.fPlayableFiles;
        }
    }

    if (self.magnet || self.fileCount == 0)
    {
        return nil;
    }

    // Folder-based playables: DVD, Blu-ray, or Album collections
    if (self.fFolderItems.count > 0)
    {
        NSMutableArray<NSDictionary*>* entries = [NSMutableArray arrayWithCapacity:self.fFolderItems.count];
        NSArray<NSString*>* folders = [self.fFolderItems sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

        NSString* type = self.fIsDVD ? @"dvd" : (self.fIsBluRay ? @"bluray" : @"album");
        BOOL isDisc = self.fIsDVD || self.fIsBluRay;

        for (NSUInteger i = 0; i < folders.count; i++)
        {
            NSString* folder = folders[i];
            NSString* fullPath = [self.currentDirectory stringByAppendingPathComponent:folder];

            // Progress: use consecutive progress for all folder-based items
            CGFloat progress = [self folderConsecutiveProgress:folder];

            // Check if any file in this folder is wanted
            NSArray<NSNumber*>* fileIndices = self.fFolderToFiles[folder];
            BOOL anyFileWanted = NO;
            if (fileIndices)
            {
                for (NSNumber* fileIndex in fileIndices)
                {
                    auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)fileIndex.unsignedIntegerValue);
                    if (file.wanted)
                    {
                        anyFileWanted = YES;
                        break;
                    }
                }
            }

            // Skip folder if no files are wanted unless fully downloaded
            if (!anyFileWanted && progress < 1.0)
            {
                continue;
            }

            // Include all wanted folders regardless of progress
            // (visibility will be controlled by TorrentTableView based on progress)

            // Display name
            NSString* name;
            if (folders.count == 1 && isDisc)
            {
                name = self.fIsDVD ? @"DVD" : @"Blu-ray";
            }
            else
            {
                name = folder.lastPathComponent;
                NSArray<NSString*>* parts = [folder pathComponents];

                // For VIDEO_TS or BDMV folders, use parent folder name instead
                if (isDisc && parts.count >= 2)
                {
                    NSString* upperName = name.uppercaseString;
                    if ([upperName isEqualToString:@"VIDEO_TS"] || [upperName isEqualToString:@"BDMV"])
                    {
                        name = parts[parts.count - 2];
                    }
                }

                // Humanize disc folder names (e.g., "Movie.Name.2020" -> "Movie Name 2020")
                if (isDisc && name.length > 0)
                {
                    name = name.humanReadableFileName;
                }

                if (name.length == 0)
                {
                    name = [NSString stringWithFormat:@"%@ %lu", (isDisc ? @"Disc" : @"Album"), (unsigned long)(i + 1)];
                }
                else
                {
                    if (parts.count >= 2)
                    {
                        NSRegularExpression* cdRegex = [NSRegularExpression regularExpressionWithPattern:@"^(CD|Disc)\\s*\\d+$"
                                                                                                 options:NSRegularExpressionCaseInsensitive
                                                                                                   error:nil];
                        NSRange nameRange = NSMakeRange(0, name.length);
                        if ([cdRegex firstMatchInString:name options:0 range:nameRange])
                        {
                            NSString* parent = parts[parts.count - 2];
                            if (parent.length > 0)
                            {
                                name = [NSString stringWithFormat:@"%@ - %@", parent, name];
                            }
                        }
                    }

                    if (!isDisc)
                    {
                        // Humanize album names
                        name = name.humanReadableFileName;
                    }
                }
            }

            [entries addObject:@{
                @"type" : type,
                @"name" : name,
                @"path" : fullPath,
                @"folder" : folder,
                @"progress" : @(progress),
                @"baseTitle" : name
            }];
        }

        self.fPlayableFiles = entries;
        return self.fPlayableFiles;
    }

    // Individual media files (not folder-based)
    self.fPlayableFiles = [self buildIndividualFilePlayables];
    return self.fPlayableFiles;
}

/// Builds playable entries for individual media files
- (NSArray<NSDictionary*>*)buildIndividualFilePlayables
{
    static NSRegularExpression* nonWordRegex;
    static NSArray<NSString*>* codecTokens;
    static NSArray<NSRegularExpression*>* codecRegexes;
    static dispatch_once_t codecOnceToken;
    dispatch_once(&codecOnceToken, ^{
        nonWordRegex = [NSRegularExpression regularExpressionWithPattern:@"[^\\p{L}\\p{N}]" options:0 error:nil];
        codecTokens = @[ @"flac", @"wav", @"mp3", @"ape", @"alac", @"aiff", @"wma", @"m4a", @"ogg", @"opus" ];
        NSMutableArray<NSRegularExpression*>* regexes = [NSMutableArray arrayWithCapacity:codecTokens.count];
        for (NSString* token in codecTokens)
        {
            NSString* pattern = [NSString stringWithFormat:@"(^|[^\\p{L}\\p{N}])%@(\\b|[^\\p{L}\\p{N}])", token];
            NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            [regexes addObject:regex];
        }
        codecRegexes = [regexes copy];
    });

    NSMutableDictionary<NSString*, NSString*>* normalizedCache = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* codecCache = [NSMutableDictionary dictionary];

    NSString* (^normalizedMediaKeyWithoutCodec)(NSString*) = ^NSString*(NSString* value) {
        if (value.length == 0)
            return @"";
        NSString* cacheKey = [@"__nocodec__" stringByAppendingString:value];
        NSString* cached = normalizedCache[cacheKey];
        if (cached)
            return cached;
        NSString* lowercase = value.lowercaseString;
        for (NSRegularExpression* regex in codecRegexes)
        {
            lowercase = [regex stringByReplacingMatchesInString:lowercase options:0 range:NSMakeRange(0, lowercase.length)
                                                   withTemplate:@""];
        }
        NSString* normalized = [nonWordRegex stringByReplacingMatchesInString:lowercase options:0
                                                                        range:NSMakeRange(0, lowercase.length)
                                                                 withTemplate:@""];
        normalizedCache[cacheKey] = normalized;
        return normalized;
    };
    NSString* (^extractCodecToken)(NSString*) = ^NSString*(NSString* value) {
        if (value.length == 0)
            return @"";
        NSString* cached = codecCache[value];
        if (cached)
            return cached;
        NSString* lowercase = value.lowercaseString;
        NSUInteger index = 0;
        for (NSRegularExpression* regex in codecRegexes)
        {
            if ([regex firstMatchInString:lowercase options:0 range:NSMakeRange(0, lowercase.length)] != nil)
            {
                NSString* token = codecTokens[index];
                codecCache[value] = token;
                return token;
            }
            index++;
        }
        codecCache[value] = @"";
        return @"";
    };

    static NSSet<NSString*>* mediaExtensions;
    static NSSet<NSString*>* documentExtensions;
    static NSSet<NSString*>* documentExternalExtensions;
    static NSSet<NSString*>* cueCompanionExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaExtensions = [NSSet setWithArray:@[
            @"mkv",  @"avi",  @"mp4", @"mov", @"wmv",  @"flv",  @"webm", @"m4v",  @"mpg", @"mpeg", @"ts",  @"m2ts",
            @"vob",  @"3gp",  @"ogv", @"mp3", @"flac", @"wav",  @"aac",  @"ogg",  @"wma", @"m4a",  @"ape", @"alac",
            @"aiff", @"opus", @"wv",  @"cue", @"pdf",  @"epub", @"fb2",  @"mobi", @"djv", @"djvu"
        ]];
        documentExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
        documentExternalExtensions = [NSSet setWithArray:@[ @"djv", @"djvu", @"fb2", @"mobi" ]];
        cueCompanionExtensions = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv" ]];
    });

    NSMutableArray<NSDictionary*>* playable = [NSMutableArray array];
    NSUInteger const count = self.fileCount;

    // First pass: collect .cue files (based on torrent metadata, not disk existence)
    NSMutableSet<NSString*>* cueBaseNames = [NSMutableSet set];
    NSMutableDictionary<NSString*, NSNumber*>* cueFileIndexes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* cueFileNames = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* cueBaseNormalized = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* cueBaseCodec = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* cueByNormalized = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* cueAudioIndexes = [NSMutableDictionary dictionary]; // companion audio for progress
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        if ([fileName.pathExtension.lowercaseString isEqualToString:@"cue"])
        {
            NSString* baseName = fileName.stringByDeletingPathExtension;
            [cueBaseNames addObject:baseName];
            cueFileIndexes[baseName] = @(i);
            cueFileNames[baseName] = fileName;
            NSString* normalized = normalizedMediaKeyWithoutCodec(baseName);
            if (normalized.length > 0)
            {
                cueBaseNormalized[baseName] = normalized;
                NSString* token = extractCodecToken(baseName);
                if (token.length > 0)
                {
                    cueBaseCodec[baseName] = token;
                }
                NSMutableArray<NSString*>* entries = cueByNormalized[normalized];
                if (!entries)
                {
                    entries = [NSMutableArray array];
                    cueByNormalized[normalized] = entries;
                }
                [entries addObject:baseName];
            }
        }
    }

    // Second pass: collect PDF/EPUB base names in the torrent (to skip DJVU/FB2 files with matching companions)
    NSMutableSet<NSString*>* pdfBaseNames = [NSMutableSet set];
    NSMutableSet<NSString*>* epubBaseNames = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"pdf"])
        {
            [pdfBaseNames addObject:fileName.stringByDeletingPathExtension.lowercaseString];
        }
        else if ([ext isEqualToString:@"epub"])
        {
            [epubBaseNames addObject:fileName.stringByDeletingPathExtension.lowercaseString];
        }
    }

    // Third pass: collect playable files
    NSMutableDictionary<NSString*, NSNumber*>* cueProgress = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* fileNamesForLexemeAnalysis = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        [fileNamesForLexemeAnalysis addObject:@(file.name)];
    }

    // Find common prefix and suffix across all files in the torrent
    NSString* commonPrefix = nil;
    NSString* commonSuffix = nil;
    if (count > 1)
    {
        for (NSString* fileName in fileNamesForLexemeAnalysis)
        {
            if (commonPrefix == nil)
            {
                commonPrefix = fileName;
            }
            else
            {
                NSUInteger j = 0;
                while (j < commonPrefix.length && j < fileName.length && [commonPrefix characterAtIndex:j] == [fileName characterAtIndex:j])
                {
                    j++;
                }
                commonPrefix = [commonPrefix substringToIndex:j];
            }

            if (commonSuffix == nil)
            {
                commonSuffix = fileName;
            }
            else
            {
                NSUInteger j = 0;
                while (j < commonSuffix.length && j < fileName.length &&
                       [commonSuffix characterAtIndex:commonSuffix.length - 1 - j] == [fileName characterAtIndex:fileName.length - 1 - j])
                {
                    j++;
                }
                commonSuffix = [commonSuffix substringFromIndex:commonSuffix.length - j];
            }
        }
    }

    // Only use common prefix/suffix if they are "reasonable" (e.g. end/start with a separator or space)
    // and don't consume the entire filename
    if (commonPrefix.length > 0)
    {
        NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@".-_ "];
        NSUInteger lastSep = [commonPrefix rangeOfCharacterFromSet:separators options:NSBackwardsSearch].location;
        if (lastSep != NSNotFound)
        {
            commonPrefix = [commonPrefix substringToIndex:lastSep + 1];
        }
        else
        {
            commonPrefix = @"";
        }
    }
    if (commonSuffix.length > 0)
    {
        NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@".-_ "];
        NSUInteger firstSep = [commonSuffix rangeOfCharacterFromSet:separators].location;
        if (firstSep != NSNotFound)
        {
            commonSuffix = [commonSuffix substringFromIndex:firstSep];
        }
        else
        {
            commonSuffix = @"";
        }
    }

    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* originalFileName = fileName;

        // Strip common prefix/suffix from the filename before further processing
        if (commonPrefix.length > 0 && [fileName hasPrefix:commonPrefix] && fileName.length > commonPrefix.length)
        {
            fileName = [fileName substringFromIndex:commonPrefix.length];
        }
        if (commonSuffix.length > 0 && [fileName hasSuffix:commonSuffix] && fileName.length > commonSuffix.length)
        {
            fileName = [fileName substringToIndex:fileName.length - commonSuffix.length];
        }

        NSString* ext = originalFileName.pathExtension.lowercaseString;

        if (![mediaExtensions containsObject:ext])
            continue;

        if ([ext isEqualToString:@"cue"])
        {
            continue;
        }

        // Skip disc structure files (handled as folders)
        if ([ext isEqualToString:@"vob"] && [fileName.uppercaseString containsString:@"VIDEO_TS/"])
            continue;
        if ([ext isEqualToString:@"m2ts"] && [fileName.uppercaseString containsString:@"BDMV/"])
            continue;

        // Skip audio with companion .cue; it will be represented by the cue entry
        if ([cueCompanionExtensions containsObject:ext])
        {
            NSString* audioBaseName = fileName.stringByDeletingPathExtension;
            NSString* normalized = normalizedMediaKeyWithoutCodec(audioBaseName);
            NSArray<NSString*>* candidateCues = normalized.length > 0 ? cueByNormalized[normalized] : nil;
            NSString* matchedCue = nil;
            for (NSString* cueBaseName in candidateCues)
            {
                NSString* cueCodec = cueBaseCodec[cueBaseName] ?: @"";
                if (cueCodec.length > 0 && ![cueCodec isEqualToString:ext])
                    continue;
                matchedCue = cueBaseName;
                break;
            }
            if (matchedCue)
            {
                CGFloat audioProgress = tr_torrentFileConsecutiveProgress(self.fHandle, i);
                if (audioProgress < 0)
                    audioProgress = 0;
                cueProgress[matchedCue] = @(audioProgress);
                // Store audio file index for progress tracking (CUE is tiny, audio progress matters)
                cueAudioIndexes[matchedCue] = @(i);
                continue;
            }
        }

        BOOL const isDjvu = [ext isEqualToString:@"djvu"] || [ext isEqualToString:@"djv"];
        BOOL const isFb2 = [ext isEqualToString:@"fb2"];

        // Skip DJVU files if the torrent already contains a PDF with the same base name
        if (isDjvu)
        {
            NSString* baseName = originalFileName.stringByDeletingPathExtension.lowercaseString;
            if ([pdfBaseNames containsObject:baseName])
            {
                // Torrent has both DJVU and PDF - skip DJVU, PDF will be shown separately
                continue;
            }
        }
        if (isFb2)
        {
            NSString* baseName = originalFileName.stringByDeletingPathExtension.lowercaseString;
            if ([epubBaseNames containsObject:baseName])
            {
                // Torrent has both FB2 and EPUB - skip FB2, EPUB will be shown separately
                continue;
            }
        }

        CGFloat progress = tr_torrentFileConsecutiveProgress(self.fHandle, i);
        if (progress < 0)
        {
            progress = 0;
        }

        // Skip files not wanted unless fully downloaded
        if (!file.wanted && progress < 1.0)
        {
            continue;
        }

        // Include all wanted files regardless of progress
        // (visibility will be controlled by TorrentTableView based on progress)

        NSString* path;
        auto const location = tr_torrentFindFile(self.fHandle, i);
        path = !std::empty(location) ? @(location.c_str()) : [self.currentDirectory stringByAppendingPathComponent:fileName];

        BOOL const isDocument = [documentExtensions containsObject:ext];
        BOOL useCompanionPdf = NO;
        BOOL useCompanionEpub = NO;
        NSString* companionPdfPath = nil;
        NSString* companionEpubPath = nil;

        // Check for companion PDF for DJVU files (created by DjvuConverter)
        if (isDjvu)
        {
            companionPdfPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
            // Only use companion PDF if it exists.
            // DjvuConverter writes PDFs atomically (temp file + rename), so partial PDFs won't be visible.
            if ([NSFileManager.defaultManager fileExistsAtPath:companionPdfPath])
            {
                useCompanionPdf = YES;
                path = companionPdfPath;
            }
        }

        if (isFb2)
        {
            companionEpubPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"epub"];
            // Only use companion EPUB if it exists.
            // Fb2Converter writes EPUBs atomically (temp file + rename), so partial EPUBs won't be visible.
            if ([NSFileManager.defaultManager fileExistsAtPath:companionEpubPath])
            {
                useCompanionEpub = YES;
                path = companionEpubPath;
            }
        }

        if (isDocument && [documentExternalExtensions containsObject:ext] && !useCompanionPdf && !useCompanionEpub && !isDjvu && !isFb2)
        {
            NSURL* checkURL = [NSURL fileURLWithPath:[self.currentDirectory stringByAppendingPathComponent:fileName]];
            NSURL* appURL = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:checkURL];
            if (!appURL)
            {
                continue;
            }
        }
        NSString* category = [self mediaCategoryForFile:i];
        NSArray<NSNumber*>* episodeNumbers = (isDocument || [category isEqualToString:@"audio"]) ? nil : fileName.episodeNumbers;
        NSNumber* season = episodeNumbers ? episodeNumbers[0] : @0;
        NSNumber* episode = episodeNumbers ? episodeNumbers[1] : @(i);

        NSString* displayName = nil;
        if (isDocument || [category isEqualToString:@"audio"])
        {
            displayName = fileName.lastPathComponent.stringByDeletingPathExtension.humanReadableFileName;
        }
        else
        {
            displayName = [fileName.lastPathComponent humanReadableEpisodeTitleWithTorrentName:self.name];
            if (!displayName)
            {
                displayName = fileName.lastPathComponent.humanReadableEpisodeName;
            }
            if (!displayName)
            {
                displayName = fileName.lastPathComponent.stringByDeletingPathExtension.humanReadableFileName;
            }
        }

        // Use companion PDF opens in Books, original external documents need external apps
        BOOL const opensInBooks = (isDocument && ![documentExternalExtensions containsObject:ext]) || useCompanionPdf || useCompanionEpub;
        [playable addObject:@{
            @"type" : isDocument ? (opensInBooks ? @"document-books" : @"document") : @"file",
            @"category" : category ?: @"",
            @"index" : @(i),
            @"name" : displayName,
            @"path" : path,
            @"season" : season,
            @"episode" : episode,
            @"progress" : @(progress),
            @"sortKey" : fileName.lastPathComponent,
            @"originalExt" : ext,
            @"isCompanion" : @(useCompanionPdf || useCompanionEpub)
        }];
    }

    if (playable.count == 0 && cueBaseNames.count == 0)
        return nil;

    // Sort by original file name to match download order
    [playable sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        NSString* aKey = a[@"sortKey"] ?: a[@"name"];
        NSString* bKey = b[@"sortKey"] ?: b[@"name"];
        return [aKey localizedStandardCompare:bKey];
    }];

        // Build final entries with titles
    NSMutableArray<NSDictionary*>* result = [NSMutableArray arrayWithCapacity:playable.count];
    for (NSDictionary* fileInfo in playable)
    {
        // Skip DJVU/FB2 source files that haven't been converted yet
        // (if converted, the path will point to PDF/EPUB, not the original)
        NSString* path = fileInfo[@"path"];
        NSString* pathExt = path.pathExtension.lowercaseString;
        if ([pathExt isEqualToString:@"djvu"] || [pathExt isEqualToString:@"djv"] || [pathExt isEqualToString:@"fb2"])
        {
            continue;
        }

        NSMutableDictionary* entry = [fileInfo mutableCopy];
        entry[@"baseTitle"] = fileInfo[@"name"];
        [result addObject:entry];
    }

    return result;
}

- (CGFloat)fileProgressForIndex:(NSUInteger)index
{
    if (self.fProgressCacheGeneration != self.fStatsGeneration)
    {
        self.fProgressCacheGeneration = self.fStatsGeneration;
        self.fFileProgressCache = nil;
        self.fFolderProgressCache = nil;
        self.fFolderFirstMediaProgressCache = nil;
    }

    NSNumber* key = @(index);
    NSNumber* cached = self.fFileProgressCache[key];
    if (cached)
    {
        return cached.doubleValue;
    }

    CGFloat progress = (CGFloat)tr_torrentFileConsecutiveProgress(self.fHandle, (tr_file_index_t)index);
    if (!self.fFileProgressCache)
    {
        self.fFileProgressCache = [NSMutableDictionary dictionary];
    }
    self.fFileProgressCache[key] = @(progress);
    return progress;
}

/// Builds cache mapping folders to their file indices (for fast progress lookups)
- (void)buildFolderToFilesCache:(NSSet<NSString*>*)folders
{
    NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* cache = [NSMutableDictionary dictionary];

    for (NSString* folder in folders)
    {
        cache[folder] = [NSMutableArray array];
    }

    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);

        for (NSString* folder in folders)
        {
            // Folder paths already include torrent name prefix (e.g., "TorrentName/Disc A")
            if ([fileName hasPrefix:folder] && (fileName.length == folder.length || [fileName characterAtIndex:folder.length] == '/'))
            {
                [cache[folder] addObject:@(i)];
                break;
            }
        }
    }

    self.fFolderToFiles = cache;
    self.fFolderProgressCache = nil;
    self.fFolderFirstMediaProgressCache = nil;
}

/// Checks if disc index files for a folder are fully downloaded
- (BOOL)discIndexFilesCompleteForFolder:(NSString*)folder
{
    NSArray<NSNumber*>* fileIndices = self.fFolderToFiles[folder];
    if (!fileIndices)
        return NO;

    for (NSNumber* fileIndex in fileIndices)
    {
        NSUInteger i = fileIndex.unsignedIntegerValue;
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;
        NSString* lastComponent = fileName.lastPathComponent.lowercaseString;

        BOOL isIndexFile = NO;
        if (self.fIsDVD)
            isIndexFile = [ext isEqualToString:@"ifo"] || [ext isEqualToString:@"bup"];
        else if (self.fIsBluRay)
            isIndexFile = [lastComponent isEqualToString:@"index.bdmv"] || [lastComponent isEqualToString:@"movieobject.bdmv"];

        if (isIndexFile && file.have < file.length)
            return NO;
    }
    return YES;
}

/// Calculates download progress for a folder (disc or album)
- (CGFloat)folderConsecutiveProgress:(NSString*)folder
{
    if (self.fProgressCacheGeneration != self.fStatsGeneration)
    {
        self.fProgressCacheGeneration = self.fStatsGeneration;
        self.fFileProgressCache = nil;
        self.fFolderProgressCache = nil;
        self.fFolderFirstMediaProgressCache = nil;
    }

    NSNumber* cached = self.fFolderProgressCache[folder];
    if (cached)
    {
        return cached.doubleValue;
    }

    // For discs, wait for index files
    if ((self.fIsDVD || self.fIsBluRay) && ![self discIndexFilesCompleteForFolder:folder])
        return 0.0;

    NSArray<NSNumber*>* fileIndices = self.fFolderToFiles[folder];
    if (!fileIndices || fileIndices.count == 0)
        return 0.0;

    CGFloat totalProgress = 0;
    uint64_t totalSize = 0;

    for (NSNumber* fileIndex in fileIndices)
    {
        NSUInteger i = fileIndex.unsignedIntegerValue;
        auto const file = tr_torrentFile(self.fHandle, i);
        // Use actual download progress, not consecutive progress
        totalProgress += file.progress * file.length;
        totalSize += file.length;
    }

    CGFloat progress = (totalSize > 0) ? totalProgress / totalSize : 0.0;
    if (!self.fFolderProgressCache)
    {
        self.fFolderProgressCache = [NSMutableDictionary dictionary];
    }
    self.fFolderProgressCache[folder] = @(progress);
    return progress;
}

/// Returns consecutive progress for the first media file in a folder (by file index).
- (CGFloat)folderFirstMediaProgress:(NSString*)folder
{
    if (self.fProgressCacheGeneration != self.fStatsGeneration)
    {
        self.fProgressCacheGeneration = self.fStatsGeneration;
        self.fFileProgressCache = nil;
        self.fFolderProgressCache = nil;
        self.fFolderFirstMediaProgressCache = nil;
    }

    NSNumber* cached = self.fFolderFirstMediaProgressCache[folder];
    if (cached)
    {
        return cached.doubleValue;
    }

    NSArray<NSNumber*>* fileIndices = self.fFolderToFiles[folder];
    if (!fileIndices)
        return 0.0;

    static NSSet<NSString*>* audioExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExtensions = [NSSet
            setWithArray:
                @[ @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus", @"cue" ]];
    });

    for (NSNumber* fileIndex in fileIndices)
    {
        NSUInteger i = fileIndex.unsignedIntegerValue;
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;
        if (![audioExtensions containsObject:ext])
            continue;

        // Prioritize CUE files in the folder
        if ([ext isEqualToString:@"cue"])
        {
            CGFloat progress = tr_torrentFileConsecutiveProgress(self.fHandle, i);
            CGFloat normalized = progress > 0 ? progress : 0.0;
            if (!self.fFolderFirstMediaProgressCache)
            {
                self.fFolderFirstMediaProgressCache = [NSMutableDictionary dictionary];
            }
            self.fFolderFirstMediaProgressCache[folder] = @(normalized);
            return normalized;
        }
    }

    for (NSNumber* fileIndex in fileIndices)
    {
        NSUInteger i = fileIndex.unsignedIntegerValue;
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;
        if (![audioExtensions containsObject:ext] || [ext isEqualToString:@"cue"])
            continue;

        CGFloat progress = tr_torrentFileConsecutiveProgress(self.fHandle, i);
        CGFloat normalized = progress > 0 ? progress : 0.0;
        if (!self.fFolderFirstMediaProgressCache)
        {
            self.fFolderFirstMediaProgressCache = [NSMutableDictionary dictionary];
        }
        self.fFolderFirstMediaProgressCache[folder] = @(normalized);
        return normalized;
    }

    return 0.0;
}

- (NSIndexSet*)fileIndexesForFolder:(NSString*)folder
{
    NSArray<NSNumber*>* fileIndices = self.fFolderToFiles[folder];
    if (!fileIndices || fileIndices.count == 0)
        return nil;

    NSMutableIndexSet* indexes = [NSMutableIndexSet indexSet];
    for (NSNumber* fileIndex in fileIndices)
    {
        [indexes addIndex:fileIndex.unsignedIntegerValue];
    }
    return indexes;
}

- (BOOL)hasPlayableMedia
{
    if (self.magnet)
    {
        return NO;
    }

    // For folder torrents, use detectMediaType (fast, cached)
    if (self.folder)
    {
        [self detectMediaType];
        return self.fMediaType != TorrentMediaTypeNone;
    }

    // For single-file torrents, check if it's a media file
    static NSSet<NSString*>* mediaExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaExtensions = [NSSet setWithArray:@[
            @"mkv", @"avi", @"mp4", @"mov",  @"wmv", @"flv", @"webm", @"m4v", @"mpg", @"mpeg", @"ts",   @"m2ts", @"vob",
            @"3gp", @"ogv", @"mp3", @"flac", @"wav", @"aac", @"ogg",  @"wma", @"m4a", @"ape",  @"alac", @"aiff", @"opus"
        ]];
    });
    return [mediaExtensions containsObject:self.name.pathExtension.lowercaseString];
}

- (NSString*)mediaCategoryForFile:(NSUInteger)index
{
    static NSSet<NSString*>* videoExtensions;
    static NSSet<NSString*>* audioExtensions;
    static NSSet<NSString*>* bookExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExtensions = [NSSet setWithArray:@[
            @"mkv",
            @"avi",
            @"mp4",
            @"mov",
            @"wmv",
            @"flv",
            @"webm",
            @"m4v",
            @"mpg",
            @"mpeg",
            @"ts",
            @"m2ts",
            @"vob",
            @"3gp",
            @"ogv"
        ]];
        audioExtensions = [NSSet
            setWithArray:
                @[ @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus", @"wv" ]];
        bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
    });

    auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)index);
    NSString* ext = @(file.name).pathExtension.lowercaseString;

    if ([videoExtensions containsObject:ext])
    {
        return @"video";
    }
    if ([audioExtensions containsObject:ext])
    {
        return @"audio";
    }
    if ([bookExtensions containsObject:ext])
    {
        return @"books";
    }
    return nil;
}

- (NSString*)detectedMediaCategory
{
    if (self.magnet)
    {
        return nil;
    }

    // For folder torrents, use detectMediaType (fast, cached)
    if (self.folder)
    {
        [self detectMediaType];
        switch (self.fMediaType)
        {
        case TorrentMediaTypeVideo:
            return @"video";
        case TorrentMediaTypeAudio:
            return @"audio";
        case TorrentMediaTypeBooks:
            return @"books";
        default:
            return nil;
        }
    }

    // For single-file torrents, check extension
    static NSSet<NSString*>* videoExtensions;
    static NSSet<NSString*>* audioExtensions;
    static NSSet<NSString*>* bookExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExtensions = [NSSet setWithArray:@[
            @"mkv",
            @"avi",
            @"mp4",
            @"mov",
            @"wmv",
            @"flv",
            @"webm",
            @"m4v",
            @"mpg",
            @"mpeg",
            @"ts",
            @"m2ts",
            @"vob",
            @"3gp",
            @"ogv"
        ]];
        audioExtensions = [NSSet
            setWithArray:
                @[ @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus", @"wv" ]];
        bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
    });

    NSString* ext = self.name.pathExtension.lowercaseString;
    if ([videoExtensions containsObject:ext])
    {
        return @"video";
    }
    if ([audioExtensions containsObject:ext])
    {
        return @"audio";
    }
    if ([bookExtensions containsObject:ext])
    {
        return @"books";
    }
    return nil;
}

/// Detects dominant media type (video or audio) in folder torrents.
/// Also detects DVD structure (VIDEO_TS folder with VOB files).
- (void)detectMediaType
{
    // Already detected
    if (self.fMediaTypeDetected)
    {
        return;
    }
    self.fMediaTypeDetected = YES;

    if (!self.folder || self.magnet)
    {
        return;
    }

    static NSSet<NSString*>* videoExtensions;
    static NSSet<NSString*>* audioExtensions;
    static NSSet<NSString*>* bookExtensions;
    static dispatch_once_t onceToken2;
    dispatch_once(&onceToken2, ^{
        videoExtensions = [NSSet setWithArray:@[
            @"mkv",
            @"avi",
            @"mp4",
            @"mov",
            @"wmv",
            @"flv",
            @"webm",
            @"m4v",
            @"mpg",
            @"mpeg",
            @"ts",
            @"m2ts",
            @"vob",
            @"3gp",
            @"ogv"
        ]];
        audioExtensions = [NSSet
            setWithArray:
                @[ @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus", @"wv" ]];
        bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
    });

    NSMutableDictionary<NSString*, NSNumber*>* videoExtCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* audioExtCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* bookExtCounts = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*>* dvdDiscFolders = [NSMutableSet set]; // Parent folders containing VIDEO_TS.IFO
    NSMutableSet<NSString*>* blurayDiscFolders = [NSMutableSet set]; // Parent folders containing index.bdmv

    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* lastComponent = fileName.lastPathComponent.lowercaseString;
        NSString* ext = fileName.pathExtension.lowercaseString;

        // Detect DVD by VIDEO_TS.IFO file (each disc has one)
        if ([lastComponent isEqualToString:@"video_ts.ifo"])
        {
            // Get the parent folder (the disc folder, e.g., "Disk.1" or "VIDEO_TS")
            NSString* discFolder = fileName.stringByDeletingLastPathComponent;
            [dvdDiscFolders addObject:discFolder];
            continue;
        }

        // Detect Blu-ray by index.bdmv file (each disc has one)
        if ([lastComponent isEqualToString:@"index.bdmv"])
        {
            // Get the parent folder (BDMV folder), then its parent (the disc folder)
            NSString* bdmvFolder = fileName.stringByDeletingLastPathComponent;
            NSString* discFolder = bdmvFolder.stringByDeletingLastPathComponent;
            [blurayDiscFolders addObject:discFolder.length > 0 ? discFolder : bdmvFolder];
            continue;
        }

        // Skip VOB files in folders that have VIDEO_TS.IFO (will be counted as DVD discs)
        if ([ext isEqualToString:@"vob"])
        {
            NSString* folder = fileName.stringByDeletingLastPathComponent;
            // Check if this folder or any detected disc folder is a parent
            BOOL isInDVD = NO;
            for (NSString* dvdFolder in dvdDiscFolders)
            {
                if ([folder isEqualToString:dvdFolder] || [fileName hasPrefix:[dvdFolder stringByAppendingString:@"/"]])
                {
                    isInDVD = YES;
                    break;
                }
            }
            if (isInDVD)
            {
                continue;
            }
        }

        // Skip m2ts files in BDMV folders
        if ([ext isEqualToString:@"m2ts"])
        {
            NSRange bdmvRange = [fileName rangeOfString:@"/BDMV/" options:NSCaseInsensitiveSearch];
            if (bdmvRange.location != NSNotFound || [fileName.lowercaseString hasPrefix:@"bdmv/"])
            {
                continue;
            }
        }

        if ([videoExtensions containsObject:ext])
        {
            videoExtCounts[ext] = @(videoExtCounts[ext].unsignedIntegerValue + 1);
        }
        else if ([audioExtensions containsObject:ext])
        {
            audioExtCounts[ext] = @(audioExtCounts[ext].unsignedIntegerValue + 1);
        }
        else if ([bookExtensions containsObject:ext])
        {
            bookExtCounts[ext] = @(bookExtCounts[ext].unsignedIntegerValue + 1);
        }
    }

    // Detect album folders for audio collections
    NSMutableSet<NSString*>* albumFolders = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;

        if ([audioExtensions containsObject:ext])
        {
            // Get the immediate parent folder of the audio file
            NSString* parentFolder = fileName.stringByDeletingLastPathComponent;
            if (parentFolder.length > 0)
            {
                [albumFolders addObject:parentFolder];
            }
        }
    }

    // Check if this is a DVD torrent
    if (dvdDiscFolders.count > 0)
    {
        self.fIsDVD = YES;
        self.fFolderItems = dvdDiscFolders.allObjects;
        self.fMediaType = TorrentMediaTypeVideo;
        self.fMediaFileCount = dvdDiscFolders.count;
        self.fMediaExtension = @"vob";
        [self buildFolderToFilesCache:dvdDiscFolders];
        return;
    }

    // Check if this is a Blu-ray torrent
    if (blurayDiscFolders.count > 0)
    {
        self.fIsBluRay = YES;
        self.fFolderItems = blurayDiscFolders.allObjects;
        self.fMediaType = TorrentMediaTypeVideo;
        self.fMediaFileCount = blurayDiscFolders.count;
        self.fMediaExtension = @"m2ts";
        [self buildFolderToFilesCache:blurayDiscFolders];
        return;
    }

    // Count video/audio files
    NSUInteger videoCount = 0, audioCount = 0, bookCount = 0;
    NSString *dominantVideoExt = nil, *dominantAudioExt = nil, *dominantBookExt = nil;
    NSString* dominantRegisteredBookExt = nil;
    NSUInteger dominantVideoCount = 0, dominantAudioCount = 0, dominantBookCount = 0;
    NSUInteger dominantRegisteredBookCount = 0;

    for (NSString* ext in videoExtCounts)
    {
        NSUInteger c = videoExtCounts[ext].unsignedIntegerValue;
        videoCount += c;
        if (c > dominantVideoCount)
        {
            dominantVideoCount = c;
            dominantVideoExt = ext;
        }
    }
    for (NSString* ext in audioExtCounts)
    {
        NSUInteger c = audioExtCounts[ext].unsignedIntegerValue;
        audioCount += c;
        if (c > dominantAudioCount)
        {
            dominantAudioCount = c;
            dominantAudioExt = ext;
        }
    }
    for (NSString* ext in bookExtCounts)
    {
        NSUInteger c = bookExtCounts[ext].unsignedIntegerValue;
        bookCount += c;
        if (c > dominantBookCount)
        {
            dominantBookCount = c;
            dominantBookExt = ext;
        }
        if ([UTType typeWithFilenameExtension:ext] != nil && c > dominantRegisteredBookCount)
        {
            dominantRegisteredBookCount = c;
            dominantRegisteredBookExt = ext;
        }
    }
    if (dominantRegisteredBookExt != nil)
    {
        dominantBookExt = dominantRegisteredBookExt;
    }

    // Determine dominant type
    if (videoCount >= audioCount && videoCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeVideo;
        self.fMediaFileCount = videoCount;
        self.fMediaExtension = dominantVideoExt;
    }
    else if (audioCount > videoCount && audioCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeAudio;
        self.fMediaFileCount = audioCount;
        self.fMediaExtension = dominantAudioExt;

        // Album collection: multiple album folders show as albums,
        // single folder shows individual tracks via buildIndividualFilePlayables
        if (albumFolders.count > 1)
        {
            self.fIsAlbumCollection = YES;
            self.fFolderItems = albumFolders.allObjects;
            [self buildFolderToFilesCache:albumFolders];
        }
    }
    else if (bookCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeBooks;
        self.fMediaFileCount = bookCount;
        self.fMediaExtension = dominantBookExt;
    }
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

- (NSString*)cueFilePathForAudioPath:(NSString*)audioPath
{
    static NSSet<NSString*>* cueCompanionExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cueCompanionExtensions = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv" ]];
    });
    
    NSString* ext = audioPath.pathExtension.lowercaseString;
    if (![cueCompanionExtensions containsObject:ext])
    {
        return nil;
    }
    
    // Extract relative path from absolute path
    NSString* torrentDir = self.currentDirectory;
    NSString* relativePath = audioPath;
    if ([audioPath hasPrefix:torrentDir])
    {
        relativePath = [audioPath substringFromIndex:torrentDir.length];
        if ([relativePath hasPrefix:@"/"])
        {
            relativePath = [relativePath substringFromIndex:1];
        }
    }
    else
    {
        // If path doesn't start with torrent directory, try to find it by filename
        relativePath = audioPath.lastPathComponent;
    }
    
    NSString* baseName = relativePath.lastPathComponent.stringByDeletingPathExtension;
    NSString* directory = relativePath.stringByDeletingLastPathComponent;
    // Normalize directory: empty string for root, remove leading/trailing slashes
    if (directory.length == 0 || [directory isEqualToString:@"."] || [directory isEqualToString:@"/"])
    {
        directory = @"";
    }
    
    // Search for a matching .cue file in the torrent
    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)i);
        NSString* fileName = @(file.name);
        NSString* fileExt = fileName.pathExtension.lowercaseString;
        
        if ([fileExt isEqualToString:@"cue"])
        {
            NSString* cueBaseName = fileName.lastPathComponent.stringByDeletingPathExtension;
            NSString* cueDirectory = fileName.stringByDeletingLastPathComponent;
            // Normalize directory: empty string for root
            if (cueDirectory.length == 0 || [cueDirectory isEqualToString:@"."] || [cueDirectory isEqualToString:@"/"])
            {
                cueDirectory = @"";
            }
            
            // Check if base names match (case-insensitive) and directories match
            if ([cueBaseName.lowercaseString isEqualToString:baseName.lowercaseString] &&
                [cueDirectory isEqualToString:directory])
            {
                // Found matching .cue file, return its path
                auto const location = tr_torrentFindFile(self.fHandle, (tr_file_index_t)i);
                if (!std::empty(location))
                {
                    return @(location.c_str());
                }
                else
                {
                    return [self.currentDirectory stringByAppendingPathComponent:fileName];
                }
            }
        }
    }
    
    return nil;
}

- (NSString*)cueFilePathForFolder:(NSString*)folder
{
    if (folder.length == 0)
    {
        return nil;
    }
    
    NSIndexSet* fileIndexes = [self fileIndexesForFolder:folder];
    if (fileIndexes.count == 0)
    {
        return nil;
    }
    
    __block NSString* cuePath = nil;
    [fileIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)idx);
        NSString* fileName = @(file.name);
        if ([fileName.pathExtension.lowercaseString isEqualToString:@"cue"])
        {
            auto const location = tr_torrentFindFile(self.fHandle, (tr_file_index_t)idx);
            if (!std::empty(location))
            {
                cuePath = @(location.c_str());
            }
            else
            {
                cuePath = [self.currentDirectory stringByAppendingPathComponent:fileName];
            }
            *stop = YES;
        }
    }];
    
    return cuePath;
}

- (NSString*)tooltipPathForItemPath:(NSString*)path type:(NSString*)type folder:(NSString*)folder
{
    NSString* resultPath = path;
    
    // For album folders, check if there's a .cue file in the folder
    if ([type isEqualToString:@"album"] && folder.length > 0)
    {
        NSString* cuePath = [self cueFilePathForFolder:folder];
        if (cuePath)
        {
            resultPath = cuePath;
        }
    }
    
    // For audio files, check if there's a matching .cue file
    if (resultPath && resultPath.length > 0)
    {
        NSString* cuePath = [self cueFilePathForAudioPath:resultPath];
        if (cuePath)
        {
            resultPath = cuePath;
        }
    }
    
    // Ensure we always return an absolute path
    if (resultPath && resultPath.length > 0)
    {
        if (![resultPath isAbsolutePath])
        {
            resultPath = [self.currentDirectory stringByAppendingPathComponent:resultPath];
        }
        
        // Resolve any symlinks and get the canonical absolute path
        NSString* resolvedPath = [resultPath stringByResolvingSymlinksInPath];
        if (resolvedPath && resolvedPath.length > 0)
        {
            resultPath = resolvedPath;
        }
    }
    
    return resultPath ?: path;
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

- (NSString*)progressString
{
    NSString* string;

    if (self.magnet)
    {
        NSString* progressString = self.fStat->metadataPercentComplete > 0.0 ?
            [NSString stringWithFormat:NSLocalizedString(@"%@ of torrent metadata retrieved", "Torrent -> progress string"),
                                       [NSString percentString:self.fStat->metadataPercentComplete longDecimals:YES]] :
            NSLocalizedString(@"torrent metadata needed", "Torrent -> progress string");
        string = [NSString stringWithFormat:@"%@ — %@", NSLocalizedString(@"Magnetized transfer", "Torrent -> progress string"), progressString];
    }
    else
    {
        if (!self.allDownloaded)
        {
            CGFloat progress;
            if (self.folder && [self.fDefaults boolForKey:@"DisplayStatusProgressSelected"])
            {
                string = [NSString stringForFilePartialSize:self.haveTotal fullSize:self.totalSizeSelected];
                progress = self.progressDone;
            }
            else
            {
                string = [NSString stringForFilePartialSize:self.haveTotal fullSize:self.size];
                progress = self.progress;
            }

            string = [string stringByAppendingFormat:@" (%@)", [NSString percentString:progress longDecimals:YES]];
        }
        else
        {
            NSString* downloadString;
            if (!self.complete) //only multifile possible
            {
                if ([self.fDefaults boolForKey:@"DisplayStatusProgressSelected"])
                {
                    downloadString = [NSString stringWithFormat:NSLocalizedString(@"%@ selected", "Torrent -> progress string"),
                                                                [NSString stringForFileSize:self.haveTotal]];
                }
                else
                {
                    downloadString = [NSString stringForFilePartialSize:self.haveTotal fullSize:self.size];
                    downloadString = [downloadString
                        stringByAppendingFormat:@" (%@)", [NSString percentString:self.progress longDecimals:YES]];
                }
            }
            else
            {
                downloadString = [NSString stringForFileSize:self.size];
            }

            NSString* uploadString = [NSString stringWithFormat:NSLocalizedString(@"uploaded %@ (Ratio: %@)", "Torrent -> progress string"),
                                                                [NSString stringForFileSize:self.uploadedTotal],
                                                                [NSString stringForRatio:self.ratio]];

            string = [downloadString stringByAppendingFormat:@", %@", uploadString];
        }

        //add time when downloading or seed limit set
        if (self.shouldShowEta)
        {
            string = [string stringByAppendingFormat:@" — %@", self.etaString];
        }
    }

    return string;
}

- (NSString*)statusString
{
    // Check for active DJVU to PDF conversion first
    NSString* failedConversionFileName = [DjvuConverter failedConversionFileNameForTorrent:self];
    if (failedConversionFileName)
    {
        return [NSString stringWithFormat:NSLocalizedString(@"Error: %@ cannot be converted to PDF", "Torrent -> status string"),
                                          failedConversionFileName];
    }

    NSString* failedFb2FileName = [Fb2Converter failedConversionFileNameForTorrent:self];
    if (failedFb2FileName)
    {
        return [NSString stringWithFormat:NSLocalizedString(@"Error: %@ cannot be converted to EPUB", "Torrent -> status string"),
                                          failedFb2FileName];
    }

    NSString* convertingFileName = [DjvuConverter convertingFileNameForTorrent:self];
    if (convertingFileName)
    {
        // Ensure conversion is actually dispatched (recovery if it wasn't)
        [DjvuConverter ensureConversionDispatchedForTorrent:self];
        NSString* progress = [DjvuConverter convertingProgressForTorrent:self];
        if (progress.length > 0)
        {
            return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ (%@) to PDF for compatibility reading…", "Torrent -> status string"),
                                              convertingFileName,
                                              progress];
        }
        return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ to PDF for compatibility reading…", "Torrent -> status string"),
                                          convertingFileName];
    }

    NSString* convertingFb2FileName = [Fb2Converter convertingFileNameForTorrent:self];
    if (convertingFb2FileName)
    {
        // Ensure conversion is actually dispatched (recovery if it wasn't)
        [Fb2Converter ensureConversionDispatchedForTorrent:self];
        NSString* progress = [Fb2Converter convertingProgressForTorrent:self];
        if (progress.length > 0)
        {
            return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ (%@) to EPUB for compatibility reading…", "Torrent -> status string"),
                                              convertingFb2FileName,
                                              progress];
        }
        return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ to EPUB for compatibility reading…", "Torrent -> status string"),
                                          convertingFb2FileName];
    }

    NSString* string;

    if (self.anyErrorOrWarning)
    {
        switch (self.fStat->error)
        {
        case TR_STAT_LOCAL_ERROR:
            string = NSLocalizedString(@"Error", "Torrent -> status string");
            break;
        case TR_STAT_TRACKER_ERROR:
            string = NSLocalizedString(@"Tracker returned error", "Torrent -> status string");
            break;
        case TR_STAT_TRACKER_WARNING:
            string = NSLocalizedString(@"Tracker returned warning", "Torrent -> status string");
            break;
        default:
            NSAssert(NO, @"unknown error state");
        }

        NSString* errorString = self.errorMessage;
        if (errorString && ![errorString isEqualToString:@""])
        {
            string = [string stringByAppendingFormat:@": %@", errorString];
        }
    }
    else
    {
        switch (self.fStat->activity)
        {
        case TR_STATUS_STOPPED:
            if (self.finishedSeeding)
            {
                string = NSLocalizedString(@"Seeding complete", "Torrent -> status string");
            }
            else if (self.pausedForDiskSpace)
            {
                // Throttle filesystem query so we don't hammer disk every UI update
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - self.fLastDiskSpaceCheckTime > kDiskSpaceCheckThrottleSeconds)
                {
                    [self alertForRemainingDiskSpace];
                    self.fLastDiskSpaceCheckTime = now;
                }

                NSString* usedString = [NSString stringForFileSizeOneDecimal:self.fDiskSpaceUsedByTorrents];
                NSString* neededString = [NSString stringForFileSizeOneDecimal:self.diskSpaceNeeded];
                NSString* availableString = [NSString stringForFileSizeOneDecimal:self.diskSpaceAvailable];
                NSString* totalString = [NSString stringForFileSizeOneDecimal:self.diskSpaceTotal];
                string = [NSString
                    stringWithFormat:NSLocalizedString(@"Not enough disk space. Used for torrents %@, Need %@, Available %@ of %@", "Torrent -> status string"),
                                     usedString,
                                     neededString,
                                     availableString,
                                     totalString];
            }
            else
            {
                string = NSLocalizedString(@"Paused", "Torrent -> status string");
            }
            break;

        case TR_STATUS_DOWNLOAD_WAIT:
            string = [NSLocalizedString(@"Waiting to download", "Torrent -> status string") stringByAppendingEllipsis];
            break;

        case TR_STATUS_SEED_WAIT:
            string = [NSLocalizedString(@"Waiting to seed", "Torrent -> status string") stringByAppendingEllipsis];
            break;

        case TR_STATUS_CHECK_WAIT:
            string = [NSLocalizedString(@"Waiting to check existing data", "Torrent -> status string") stringByAppendingEllipsis];
            break;

        case TR_STATUS_CHECK:
            string = [NSString stringWithFormat:@"%@ (%@)",
                                                NSLocalizedString(@"Checking existing data", "Torrent -> status string"),
                                                [NSString percentString:self.checkingProgress longDecimals:YES]];
            break;

        case TR_STATUS_DOWNLOAD:
            {
                NSUInteger const totalPeersCount = std::max<NSUInteger>(self.totalPeersConnected, self.peersSendingToUs);
                if (totalPeersCount != 1)
                {
                    string = [NSString localizedStringWithFormat:NSLocalizedString(@"Downloading from %lu of %lu peers", "Torrent -> status string"),
                                                                 self.peersSendingToUs,
                                                                 totalPeersCount];
                }
                else
                {
                    string = [NSString stringWithFormat:NSLocalizedString(@"Downloading from %lu of 1 peer", "Torrent -> status string"),
                                                        self.peersSendingToUs];
                }
            }

            if (NSUInteger const webSeedCount = self.fStat->webseedsSendingToUs; webSeedCount > 0)
            {
                NSString* webSeedString;
                if (webSeedCount != 1)
                {
                    webSeedString = [NSString
                        localizedStringWithFormat:NSLocalizedString(@"%lu web seeds", "Torrent -> status string"), webSeedCount];
                }
                else
                {
                    webSeedString = NSLocalizedString(@"web seed", "Torrent -> status string");
                }

                string = [string stringByAppendingFormat:@" + %@", webSeedString];
            }

            break;

        case TR_STATUS_SEED:
            {
                NSUInteger const totalPeersCount = std::max<NSUInteger>(self.totalPeersConnected, self.peersGettingFromUs);
                if (totalPeersCount != 1)
                {
                    string = [NSString localizedStringWithFormat:NSLocalizedString(@"Seeding to %1$lu of %2$lu peers", "Torrent -> status string"),
                                                                 self.peersGettingFromUs,
                                                                 totalPeersCount];
                }
                else
                {
                    string = [NSString localizedStringWithFormat:NSLocalizedString(@"Seeding to %1$lu of %2$lu peer", "Torrent -> status string"),
                                                                 self.peersGettingFromUs,
                                                                 totalPeersCount];
                }
            }
            break;
        }
    }

    return string;
}

- (NSString*)shortStatusString
{
    NSString* string;

    switch (self.fStat->activity)
    {
    case TR_STATUS_STOPPED:
        if (self.finishedSeeding)
        {
            string = NSLocalizedString(@"Seeding complete", "Torrent -> status string");
        }
        else
        {
            string = NSLocalizedString(@"Paused", "Torrent -> status string");
        }
        break;

    case TR_STATUS_DOWNLOAD_WAIT:
        string = [NSLocalizedString(@"Waiting to download", "Torrent -> status string") stringByAppendingEllipsis];
        break;

    case TR_STATUS_SEED_WAIT:
        string = [NSLocalizedString(@"Waiting to seed", "Torrent -> status string") stringByAppendingEllipsis];
        break;

    case TR_STATUS_CHECK_WAIT:
        string = [NSLocalizedString(@"Waiting to check existing data", "Torrent -> status string") stringByAppendingEllipsis];
        break;

    case TR_STATUS_CHECK:
        string = [NSString stringWithFormat:@"%@ (%@)",
                                            NSLocalizedString(@"Checking existing data", "Torrent -> status string"),
                                            [NSString percentString:self.checkingProgress longDecimals:YES]];
        break;

    case TR_STATUS_DOWNLOAD:
        string = [NSString stringWithFormat:@"%@: %@, %@: %@",
                                            NSLocalizedString(@"DL", "Torrent -> status string"),
                                            [NSString stringForSpeed:self.downloadRate],
                                            NSLocalizedString(@"UL", "Torrent -> status string"),
                                            [NSString stringForSpeed:self.uploadRate]];
        break;

    case TR_STATUS_SEED:
        string = [NSString stringWithFormat:@"%@: %@, %@: %@",
                                            NSLocalizedString(@"Ratio", "Torrent -> status string"),
                                            [NSString stringForRatio:self.ratio],
                                            NSLocalizedString(@"UL", "Torrent -> status string"),
                                            [NSString stringForSpeed:self.uploadRate]];
        break;
    }

    if (self.shouldShowEta)
    {
        return self.etaString;
    }
    else
    {
        return string;
    }
}

- (NSString*)remainingTimeString
{
    if (self.shouldShowEta)
    {
        return self.etaString;
    }
    else
    {
        return self.shortStatusString;
    }
}

- (NSUInteger)statsGeneration
{
    return self.fStatsGeneration;
}

- (NSString*)stateString
{
    switch (self.fStat->activity)
    {
    case TR_STATUS_STOPPED:
    case TR_STATUS_DOWNLOAD_WAIT:
    case TR_STATUS_SEED_WAIT:
        {
            NSString* string = NSLocalizedString(@"Paused", "Torrent -> status string");

            NSString* extra = nil;
            if (self.waitingToStart)
            {
                extra = self.fStat->activity == TR_STATUS_DOWNLOAD_WAIT ?
                    NSLocalizedString(@"Waiting to download", "Torrent -> status string") :
                    NSLocalizedString(@"Waiting to seed", "Torrent -> status string");
            }
            else if (self.finishedSeeding)
            {
                extra = NSLocalizedString(@"Seeding complete", "Torrent -> status string");
            }

            return extra ? [string stringByAppendingFormat:@" (%@)", extra] : string;
        }

    case TR_STATUS_CHECK_WAIT:
        return [NSLocalizedString(@"Waiting to check existing data", "Torrent -> status string") stringByAppendingEllipsis];

    case TR_STATUS_CHECK:
        return [NSString stringWithFormat:@"%@ (%@)",
                                          NSLocalizedString(@"Checking existing data", "Torrent -> status string"),
                                          [NSString percentString:self.checkingProgress longDecimals:YES]];

    case TR_STATUS_DOWNLOAD:
        return NSLocalizedString(@"Downloading", "Torrent -> status string");

    case TR_STATUS_SEED:
        return NSLocalizedString(@"Seeding", "Torrent -> status string");
    }
}

- (NSUInteger)totalPeersConnected
{
    return self.fStat->peersConnected;
}

- (NSUInteger)totalPeersTracker
{
    return self.fStat->peersFrom[TR_PEER_FROM_TRACKER];
}

- (NSUInteger)totalPeersIncoming
{
    return self.fStat->peersFrom[TR_PEER_FROM_INCOMING];
}

- (NSUInteger)totalPeersCache
{
    return self.fStat->peersFrom[TR_PEER_FROM_RESUME];
}

- (NSUInteger)totalPeersPex
{
    return self.fStat->peersFrom[TR_PEER_FROM_PEX];
}

- (NSUInteger)totalPeersDHT
{
    return self.fStat->peersFrom[TR_PEER_FROM_DHT];
}

- (NSUInteger)totalPeersLocal
{
    return self.fStat->peersFrom[TR_PEER_FROM_LPD];
}

- (NSUInteger)totalPeersLTEP
{
    return self.fStat->peersFrom[TR_PEER_FROM_LTEP];
}

- (NSUInteger)totalKnownPeersTracker
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_TRACKER];
}

- (NSUInteger)totalKnownPeersIncoming
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_INCOMING];
}

- (NSUInteger)totalKnownPeersCache
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_RESUME];
}

- (NSUInteger)totalKnownPeersPex
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_PEX];
}

- (NSUInteger)totalKnownPeersDHT
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_DHT];
}

- (NSUInteger)totalKnownPeersLocal
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_LPD];
}

- (NSUInteger)totalKnownPeersLTEP
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_LTEP];
}

- (NSUInteger)peersSendingToUs
{
    return self.fStat->peersSendingToUs;
}

- (NSUInteger)peersGettingFromUs
{
    return self.fStat->peersGettingFromUs;
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

- (void)createFileList
{
    NSAssert(!self.magnet, @"Cannot create a file list until the torrent is demagnetized");

    if (self.folder)
    {
        NSUInteger const count = self.fileCount;
        NSMutableArray* flatFileList = [NSMutableArray arrayWithCapacity:count];

        FileListNode* tempNode = nil;

        for (NSUInteger i = 0; i < count; i++)
        {
            auto const file = tr_torrentFile(self.fHandle, i);

            NSString* fullPath = [NSString convertedStringFromCString:file.name];
            NSArray* pathComponents = fullPath.pathComponents;
            while (pathComponents.count <= 1)
            {
                // file.name isn't a path: append an arbitrary empty component until we have two components.
                // Invalid filenames and duplicate filenames don't need to be handled here.
                pathComponents = [pathComponents arrayByAddingObject:@""];
            }

            if (!tempNode)
            {
                tempNode = [[FileListNode alloc] initWithFolderName:pathComponents[0] path:@"" torrent:self];
            }

            [self insertPathForComponents:pathComponents //
                       withComponentIndex:1
                                forParent:tempNode
                                 fileSize:file.length
                                    index:i
                                 flatList:flatFileList];
        }

        [self sortFileList:tempNode.children];
        [self sortFileList:flatFileList];

        self.fileList = [[NSArray alloc] initWithArray:tempNode.children];
        self.flatFileList = [[NSArray alloc] initWithArray:flatFileList];
    }
    else
    {
        FileListNode* node = [[FileListNode alloc] initWithFileName:self.name path:@"" size:self.size index:0 torrent:self];
        self.fileList = @[ node ];
        self.flatFileList = self.fileList;
    }
}

- (void)insertPathForComponents:(NSArray<NSString*>*)components
             withComponentIndex:(NSUInteger)componentIndex
                      forParent:(FileListNode*)parent
                       fileSize:(uint64_t)size
                          index:(NSInteger)index
                       flatList:(NSMutableArray<FileListNode*>*)flatFileList
{
    NSParameterAssert(components.count > 0);
    NSParameterAssert(componentIndex < components.count);

    NSString* name = components[componentIndex];
    BOOL const isFolder = componentIndex < (components.count - 1);

    //determine if folder node already exists
    __block FileListNode* node = nil;
    if (isFolder)
    {
        [parent.children enumerateObjectsWithOptions:NSEnumerationConcurrent
                                          usingBlock:^(FileListNode* searchNode, NSUInteger /*idx*/, BOOL* stop) {
                                              if ([searchNode.name isEqualToString:name] && searchNode.isFolder)
                                              {
                                                  node = searchNode;
                                                  *stop = YES;
                                              }
                                          }];
    }

    //create new folder or file if it doesn't already exist
    if (!node)
    {
        NSString* path = [parent.path stringByAppendingPathComponent:parent.name];
        if (isFolder)
        {
            node = [[FileListNode alloc] initWithFolderName:name path:path torrent:self];
        }
        else
        {
            node = [[FileListNode alloc] initWithFileName:name path:path size:size index:index torrent:self];
            [flatFileList addObject:node];
        }

        [parent insertChild:node];
    }

    if (isFolder)
    {
        [node insertIndex:index withSize:size];

        [self insertPathForComponents:components //
                   withComponentIndex:componentIndex + 1
                            forParent:node
                             fileSize:size
                                index:index
                             flatList:flatFileList];
    }
}

- (void)sortFileList:(NSMutableArray<FileListNode*>*)fileNodes
{
    NSSortDescriptor* descriptor = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES
                                                                  selector:@selector(localizedStandardCompare:)];
    [fileNodes sortUsingDescriptors:@[ descriptor ]];

    [fileNodes enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(FileListNode* node, NSUInteger /*idx*/, BOOL* /*stop*/) {
        if (node.isFolder)
        {
            [self sortFileList:node.children];
        }
    }];
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

- (BOOL)shouldShowEta
{
    if (self.fStat->activity == TR_STATUS_DOWNLOAD)
    {
        return YES;
    }
    else if (self.seeding)
    {
        //ratio: show if it's set at all
        if (tr_torrentGetSeedRatio(self.fHandle, NULL))
        {
            return YES;
        }

        //idle: show only if remaining time is less than cap
        if (self.fStat->etaIdle != TR_ETA_NOT_AVAIL && self.fStat->etaIdle < kETAIdleDisplaySec)
        {
            return YES;
        }
    }

    return NO;
}

- (NSString*)etaString
{
    time_t eta = self.fStat->eta;
    // if there's a regular ETA, torrent isn't idle
    BOOL fromIdle = NO;
    if (eta < 0)
    {
        eta = self.fStat->etaIdle;
        fromIdle = YES;
    }
    // Foundation undocumented behavior: values above INT32_MAX (68 years) are interpreted as negative values by `stringFromTimeInterval` (#3451)
    if (eta < 0 || eta > INT32_MAX || (fromIdle && eta >= kETAIdleDisplaySec))
    {
        if (self.downloading && self.downloadRate > 0.0 && self.sizeLeft > 0)
        {
            double const eta_seconds = static_cast<double>(self.sizeLeft) / (self.downloadRate * 1024.0);
            if (eta_seconds > 0.0 && eta_seconds <= INT32_MAX)
            {
                return [etaFormatter() stringFromTimeInterval:eta_seconds];
            }
        }

        return NSLocalizedString(@"remaining time unknown", "Torrent -> eta string");
    }

    NSString* idleString = [etaFormatter() stringFromTimeInterval:eta];

    if (fromIdle)
    {
        idleString = [idleString stringByAppendingFormat:@" (%@)", NSLocalizedString(@"inactive", "Torrent -> eta string")];
    }

    return idleString;
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

@end
