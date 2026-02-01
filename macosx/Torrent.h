// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>
#import <Quartz/Quartz.h>

#include <libtransmission/transmission.h>

@class FileListNode;

typedef NS_ENUM(NSUInteger, TorrentDeterminationType) { TorrentDeterminationAutomatic = 0, TorrentDeterminationUserSpecified };

extern NSString* const kTorrentDidChangeGroupNotification;

@interface Torrent : NSObject<NSCopying, QLPreviewItem>

- (instancetype)initWithPath:(NSString*)path
                    location:(NSString*)location
           deleteTorrentFile:(BOOL)torrentDelete
                         lib:(tr_session*)lib;
- (instancetype)initWithTorrentStruct:(tr_torrent*)torrentStruct location:(NSString*)location lib:(tr_session*)lib;
- (instancetype)initWithMagnetAddress:(NSString*)address location:(NSString*)location lib:(tr_session*)lib;
- (void)setResumeStatusForTorrent:(Torrent*)torrent withHistory:(NSDictionary*)history forcePause:(BOOL)pause;

@property(nonatomic, readonly) NSDictionary* history;

- (void)closeRemoveTorrent:(BOOL)trashFiles;
- (void)closeRemoveTorrent:(BOOL)trashFiles completionHandler:(void (^)(BOOL succeeded))completionHandler;

- (void)changeDownloadFolderBeforeUsing:(NSString*)folder determinationType:(TorrentDeterminationType)determinationType;

@property(nonatomic, readonly) NSString* currentDirectory;

- (void)getAvailability:(int8_t*)tab size:(int)size;
- (void)getAmountFinished:(float*)tab size:(int)size;
@property(nonatomic) NSIndexSet* previousFinishedPieces;

// Updates one or more torrents by refreshing their libtransmission stats.
// Prefer using this batch method when updating many torrents at once.
+ (void)updateTorrents:(NSArray<Torrent*>*)torrents;

- (void)update;

- (void)startTransferIgnoringQueue:(BOOL)ignoreQueue;
- (void)startTransferNoQueue;
- (void)startTransfer;
- (void)startMagnetTransferAfterMetaDownload;
- (void)stopTransfer;
- (void)sleep;
- (void)wakeUp;
- (void)idleLimitHit;
- (void)ratioLimitHit;
- (void)metadataRetrieved;
- (void)completenessChange:(tr_completeness)status wasRunning:(BOOL)wasRunning;

@property(nonatomic) NSUInteger queuePosition;

- (void)manualAnnounce;
@property(nonatomic, readonly) BOOL canManualAnnounce;

- (void)resetCache;

@property(nonatomic, getter=isMagnet, readonly) BOOL magnet;
@property(nonatomic, readonly) NSString* magnetLink;

@property(nonatomic, readonly) CGFloat ratio;
@property(nonatomic) tr_ratiolimit ratioSetting;
@property(nonatomic) CGFloat ratioLimit;
@property(nonatomic, readonly) CGFloat progressStopRatio;

@property(nonatomic) tr_idlelimit idleSetting;
@property(nonatomic) NSUInteger idleLimitMinutes;

- (BOOL)usesSpeedLimit:(BOOL)upload;
- (void)setUseSpeedLimit:(BOOL)use upload:(BOOL)upload;
- (NSUInteger)speedLimit:(BOOL)upload;
- (void)setSpeedLimit:(NSUInteger)limit upload:(BOOL)upload;
@property(nonatomic) BOOL usesGlobalSpeedLimit;

@property(nonatomic) uint16_t maxPeerConnect;

@property(nonatomic) BOOL removeWhenFinishSeeding;

@property(nonatomic, readonly) BOOL waitingToStart;

@property(nonatomic) tr_priority_t priority;

+ (BOOL)trashFile:(NSString*)path error:(NSError**)error;
- (void)moveTorrentDataFileTo:(NSString*)folder;
- (void)copyTorrentFileTo:(NSString*)path;

@property(nonatomic, readonly) BOOL alertForRemainingDiskSpace;
- (BOOL)alertForRemainingDiskSpaceBypassThrottle:(BOOL)bypass;

@property(nonatomic, readonly) NSImage* icon;
/// Subtitle for multi-file media torrents (e.g., "x8" for 8 video files). Nil for non-media or single file.
@property(nonatomic, readonly) NSString* iconSubtitle;

/// Array of playable media files. Each entry is a dictionary with keys:
/// - "index": NSNumber file index
/// - "name": NSString humanized display name (e.g., "E5" for episodes)
/// - "path": NSString file path on disk (nil if not downloaded)
/// Only includes files that are video/audio and exist on disk.
@property(nonatomic, readonly) NSArray<NSDictionary*>* playableFiles;
/// Best item to play from playableFiles: prefers .cue, then first with progress > 0, then first. Nil if list empty.
- (NSDictionary*)preferredPlayableItemFromList:(NSArray<NSDictionary*>*)playableFiles;

/// Returns YES if torrent has any playable media files on disk.
@property(nonatomic, readonly) BOOL hasPlayableMedia;

/// Returns detected media category: "video", "audio", "books", "software", "adult" (video with adult heuristic), or nil if none detected.
/// Used for auto-assigning torrents to groups based on content type.
@property(nonatomic, readonly) NSString* detectedMediaCategory;

/// Returns detected media category for a specific file index.
- (NSString*)mediaCategoryForFile:(NSUInteger)index;

/// Cached height for play buttons view (calculated by TorrentTableView).
@property(nonatomic) CGFloat cachedPlayButtonsHeight;
/// Cached width used for play buttons layout (calculated by TorrentTableView).
@property(nonatomic) CGFloat cachedPlayButtonsWidth;
/// Cached play button state (title/visibility) for UI rendering.
@property(nonatomic, copy) NSArray<NSDictionary*>* cachedPlayButtonState;
/// Cached source items for play button state.
@property(nonatomic, copy) NSArray<NSDictionary*>* cachedPlayButtonSource;
/// Cached play button layout (season headers + items).
@property(nonatomic, copy) NSArray<NSDictionary*>* cachedPlayButtonLayout;
/// Cached stats generation for play button progress.
@property(nonatomic) NSUInteger cachedPlayButtonProgressGeneration;
/// Cached stats generation for play menu.
@property(nonatomic) NSUInteger cachedPlayMenuGeneration;

/// Returns current file progress (0.0-1.0) for a file index.
- (CGFloat)fileProgressForIndex:(NSUInteger)index;

/// Returns consecutive progress for a folder (disc or album).
- (CGFloat)folderConsecutiveProgress:(NSString*)folder;
/// Returns consecutive progress for the first media file in a folder.
- (CGFloat)folderFirstMediaProgress:(NSString*)folder;
/// Returns file indexes for a folder if cached.
- (NSIndexSet*)fileIndexesForFolder:(NSString*)folder;

@property(nonatomic, readonly) NSString* name;
@property(nonatomic, readonly) NSString* displayName;
@property(nonatomic, getter=isFolder, readonly) BOOL folder;
@property(nonatomic, readonly) uint64_t size;
@property(nonatomic, readonly) uint64_t sizeLeft;

@property(nonatomic, readonly) NSMutableArray* allTrackerStats;
@property(nonatomic, readonly) NSArray<NSString*>* allTrackersFlat; //used by GroupRules
- (BOOL)addTrackerToNewTier:(NSString*)tracker;
- (void)removeTrackers:(NSSet*)trackers;

@property(nonatomic, readonly) NSString* comment;
@property(nonatomic, readonly) NSURL* commentURL;
@property(nonatomic, readonly) NSString* creator;
@property(nonatomic, readonly) NSDate* dateCreated;

@property(nonatomic, readonly) NSInteger pieceSize;
@property(nonatomic, readonly) NSInteger pieceCount;
@property(nonatomic, readonly) NSString* hashString;
@property(nonatomic, readonly) BOOL privateTorrent;

@property(nonatomic, readonly) NSString* torrentLocation;
@property(nonatomic, readonly) NSString* dataLocation;
/// Returns YES when none of the torrent's files exist on disk.
@property(nonatomic, readonly) BOOL allFilesMissing;
@property(nonatomic, readonly) NSString* lastKnownDataLocation;
- (NSString*)fileLocation:(FileListNode*)node;
/// Path to open for this file/folder (prefers .cue for audio/album). Nil if location unknown.
- (NSString*)pathToOpenForFileNode:(FileListNode*)node;
/// Path to open for an audio path: .cue path if companion exists, else path. Used for double-click and play.
- (NSString*)pathToOpenForAudioPath:(NSString*)path;
/// Path that would be opened for this playable item (e.g. .cue when present for audio). Used by play menu and play action.
- (NSString*)pathToOpenForPlayableItem:(NSDictionary*)item;
/// Display name for play menu; should reflect the file that is opened (e.g. .cue when present).
- (NSString*)displayNameForPlayableItem:(NSDictionary*)item;

// Returns .cue file path for a given audio file path, or nil if no matching .cue file found
- (NSString*)cueFilePathForAudioPath:(NSString*)audioPath;

// Returns .cue file path for a given folder, or nil if no .cue file found in the folder
- (NSString*)cueFilePathForFolder:(NSString*)folder;

// Returns the path to show in tooltip (prefers .cue file if available for audio files or album folders)
- (NSString*)tooltipPathForItemPath:(NSString*)path type:(NSString*)type folder:(NSString*)folder;

/// Returns self. Used as NSSortDescriptor key so comparator receives Torrent objects, not key-path values.
@property(nonatomic, readonly) Torrent* selfForSorting;

/// YES if every string in strings appears in tracker list (byTracker) or in name/playable titles (includePlayableTitles). Used by filter bar search.
- (BOOL)matchesSearchStrings:(NSArray<NSString*>*)strings
                   byTracker:(BOOL)byTracker
       includePlayableTitles:(BOOL)includePlayableTitles;
/// Count of search strings that appear (0..strings.count). Used to sort filtered list by most matched first.
- (NSUInteger)searchMatchScoreForStrings:(NSArray<NSString*>*)strings
                               byTracker:(BOOL)byTracker
                   includePlayableTitles:(BOOL)includePlayableTitles;

/// Open/play count (double-click, play menu, content buttons). Key: hash|f<index> or hash|d<folder>.
- (void)recordOpenForFileNode:(FileListNode*)node;
- (void)recordOpenForPlayableItem:(NSDictionary*)item;
- (NSUInteger)openCountForFileNode:(FileListNode*)node;
/// "Played: N" for video/audio, "Opened: N" for other, nil when count is 0.
- (NSString*)openCountLabelForFileNode:(FileListNode*)node;
- (NSString*)openCountLabelForPlayableItem:(NSDictionary*)item;

- (void)renameTorrent:(NSString*)newName completionHandler:(void (^)(BOOL didRename))completionHandler;
- (void)renameFileNode:(FileListNode*)node
              withName:(NSString*)newName
     completionHandler:(void (^)(BOOL didRename))completionHandler;

@property(nonatomic, readonly) time_t eta;
@property(nonatomic, readonly) CGFloat progress;
@property(nonatomic, readonly) CGFloat progressDone;
@property(nonatomic, readonly) CGFloat progressLeft;
@property(nonatomic, readonly) CGFloat consecutiveProgress;
@property(nonatomic, readonly) CGFloat checkingProgress;

@property(nonatomic, readonly) CGFloat availableDesired;

/// True if non-paused. Running.
@property(nonatomic, getter=isActive, readonly) BOOL active;
/// True if downloading or uploading.
@property(nonatomic, getter=isTransmitting, readonly) BOOL transmitting;
@property(nonatomic, getter=isSeeding, readonly) BOOL seeding;
/// True if actively downloading (not paused, not seeding, not just checking).
@property(nonatomic, getter=isDownloading, readonly) BOOL downloading;
@property(nonatomic, getter=isChecking, readonly) BOOL checking;
@property(nonatomic, getter=isCheckingWaiting, readonly) BOOL checkingWaiting;
@property(nonatomic, readonly) BOOL allDownloaded;
@property(nonatomic, getter=isComplete, readonly) BOOL complete;
@property(nonatomic, getter=isFinishedSeeding, readonly) BOOL finishedSeeding;
@property(nonatomic, getter=isError, readonly) BOOL error;
@property(nonatomic, getter=isAnyErrorOrWarning, readonly) BOOL anyErrorOrWarning;
@property(nonatomic, readonly) NSString* errorMessage;
@property(nonatomic, getter=isPausedForDiskSpace, readonly) BOOL pausedForDiskSpace;
@property(nonatomic, readonly) uint64_t diskSpaceNeeded;
@property(nonatomic, readonly) uint64_t diskSpaceAvailable;
@property(nonatomic, readonly) uint64_t diskSpaceTotal;
@property(nonatomic, readonly) BOOL diskSpaceDialogShown;
@property(nonatomic) BOOL fDiskSpaceDialogShown;

@property(nonatomic, readonly) NSNumber* volumeIdentifier;

@property(nonatomic, readonly) uint64_t totalTorrentDiskUsage;
@property(nonatomic, readonly) uint64_t totalTorrentDiskNeeded;

- (uint64_t)totalTorrentDiskUsageOnVolume:(NSNumber*)volumeID;
- (uint64_t)totalTorrentDiskNeededOnVolume:(NSNumber*)volumeID group:(NSInteger)groupValue;

@property(nonatomic, readonly) NSArray<NSDictionary*>* peers;

@property(nonatomic, readonly) NSUInteger webSeedCount;
@property(nonatomic, readonly) NSArray<NSDictionary*>* webSeeds;

@property(nonatomic, readonly) NSString* progressString;
@property(nonatomic, readonly) NSString* statusString;
@property(nonatomic, readonly) NSString* shortStatusString;
@property(nonatomic, readonly) NSString* remainingTimeString;
@property(nonatomic, readonly) NSUInteger statsGeneration;

@property(nonatomic) NSString* fCachedHumanReadableTitle;

@property(nonatomic, readonly) NSString* stateString;
@property(nonatomic, readonly) NSUInteger totalPeersConnected;
@property(nonatomic, readonly) NSUInteger totalPeersTracker;
@property(nonatomic, readonly) NSUInteger totalPeersIncoming;
@property(nonatomic, readonly) NSUInteger totalPeersCache;
@property(nonatomic, readonly) NSUInteger totalPeersPex;
@property(nonatomic, readonly) NSUInteger totalPeersDHT;
@property(nonatomic, readonly) NSUInteger totalPeersLocal;
@property(nonatomic, readonly) NSUInteger totalPeersLTEP;

@property(nonatomic, readonly) NSUInteger totalKnownPeersTracker;
@property(nonatomic, readonly) NSUInteger totalKnownPeersIncoming;
@property(nonatomic, readonly) NSUInteger totalKnownPeersCache;
@property(nonatomic, readonly) NSUInteger totalKnownPeersPex;
@property(nonatomic, readonly) NSUInteger totalKnownPeersDHT;
@property(nonatomic, readonly) NSUInteger totalKnownPeersLocal;
@property(nonatomic, readonly) NSUInteger totalKnownPeersLTEP;

@property(nonatomic, readonly) NSUInteger peersSendingToUs;
@property(nonatomic, readonly) NSUInteger peersGettingFromUs;

@property(nonatomic, readonly) CGFloat downloadRate;
@property(nonatomic, readonly) CGFloat uploadRate;
@property(nonatomic, readonly) CGFloat totalRate;
@property(nonatomic, readonly) uint64_t haveVerified;
@property(nonatomic, readonly) uint64_t haveTotal;
@property(nonatomic, readonly) uint64_t totalSizeSelected;
@property(nonatomic, readonly) uint64_t downloadedTotal;
@property(nonatomic, readonly) uint64_t uploadedTotal;
@property(nonatomic, readonly) uint64_t failedHash;

@property(nonatomic, readonly) NSInteger groupValue;
- (void)setGroupValue:(NSInteger)groupValue determinationType:(TorrentDeterminationType)determinationType;
;
@property(nonatomic, readonly) NSInteger groupOrderValue;
- (void)checkGroupValueForRemoval:(NSNotification*)notification;

@property(nonatomic, readonly) NSArray<FileListNode*>* fileList;
@property(nonatomic, readonly) NSArray<FileListNode*>* flatFileList;
@property(nonatomic, readonly) NSUInteger fileCount;

//methods require fileStats to have been updated recently to be accurate
- (CGFloat)fileProgress:(FileListNode*)node;
- (BOOL)canChangeDownloadCheckForFile:(NSUInteger)index;
- (BOOL)canChangeDownloadCheckForFiles:(NSIndexSet*)indexSet;
- (NSControlStateValue)checkForFiles:(NSIndexSet*)indexSet;
- (void)setFileCheckState:(NSControlStateValue)state forIndexes:(NSIndexSet*)indexSet;
- (void)setFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet*)indexSet;
- (BOOL)hasFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet*)indexSet;
- (NSSet*)filePrioritiesForIndexes:(NSIndexSet*)indexSet;

@property(nonatomic, readonly) NSDate* dateAdded;

/// Size in bytes of the torrent data selected for download
@property(nonatomic, readonly) uint64_t sizeWhenDone;
@property(nonatomic, readonly) NSDate* dateCompleted;
@property(nonatomic, readonly) NSDate* dateActivity;
@property(nonatomic, readonly) NSDate* dateActivityOrAdd;
@property(nonatomic, readonly) NSDate* dateLastPlayed;

@property(nonatomic, readonly) NSInteger secondsDownloading;
@property(nonatomic, readonly) NSInteger secondsSeeding;

@property(nonatomic, readonly) NSInteger stalledMinutes;
/// True if the torrent is running, but has been idle for long enough to be considered stalled.
@property(nonatomic, getter=isStalled, readonly) BOOL stalled;

- (void)updateTimeMachineExclude;

@property(nonatomic, readonly) NSInteger stateSortKey;
@property(nonatomic, readonly) NSString* trackerSortKey;

@property(nonatomic, readonly) tr_torrent* torrentStruct;

// Tracks whether we've verified partial data before resuming in this session
@property(nonatomic) BOOL fVerifiedOnResume;

/// Tracks file indexes that were played in the current session.
@property(nonatomic, readonly) NSMutableIndexSet* playedFiles;

@end
