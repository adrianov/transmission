// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>
#import <Quartz/Quartz.h>

#include <libtransmission/transmission.h>

@class FileListNode;

typedef NS_ENUM(NSUInteger, TorrentDeterminationType) { TorrentDeterminationAutomatic = 0, TorrentDeterminationUserSpecified };

NS_ASSUME_NONNULL_BEGIN

extern NSString* _Nonnull const kTorrentDidChangeGroupNotification;

@interface Torrent : NSObject<NSCopying, QLPreviewItem>

- (instancetype)initWithPath:(NSString* _Nonnull)path
                    location:(NSString* _Nonnull)location
           deleteTorrentFile:(BOOL)torrentDelete
                         lib:(tr_session* _Nonnull)lib;
- (instancetype)initWithTorrentStruct:(tr_torrent* _Nonnull)torrentStruct location:(NSString* _Nonnull)location lib:(tr_session* _Nonnull)lib;
- (instancetype)initWithMagnetAddress:(NSString* _Nonnull)address location:(NSString* _Nonnull)location lib:(tr_session* _Nonnull)lib;
- (void)setResumeStatusForTorrent:(Torrent* _Nonnull)torrent withHistory:(NSDictionary* _Nonnull)history forcePause:(BOOL)pause;

@property(nonatomic, readonly) NSDictionary* _Nonnull history;

- (void)closeRemoveTorrent:(BOOL)trashFiles;
- (void)closeRemoveTorrent:(BOOL)trashFiles completionHandler:(void (^ _Nullable)(BOOL succeeded))completionHandler;

- (void)changeDownloadFolderBeforeUsing:(NSString* _Nonnull)folder determinationType:(TorrentDeterminationType)determinationType;

@property(nonatomic, readonly) NSString* _Nonnull currentDirectory;

- (void)getAvailability:(int8_t* _Nonnull)tab size:(int)size;
- (void)getAmountFinished:(float* _Nonnull)tab size:(int)size;
@property(nonatomic) NSIndexSet* _Nullable previousFinishedPieces;

// Updates one or more torrents by refreshing their libtransmission stats.
// Prefer using this batch method when updating many torrents at once.
+ (void)updateTorrents:(NSArray<Torrent*>* _Nonnull)torrents;

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
@property(nonatomic, readonly) NSString* _Nonnull magnetLink;

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

+ (BOOL)trashFile:(NSString* _Nonnull)path error:(NSError* _Nullable* _Nullable)error;
- (void)moveTorrentDataFileTo:(NSString* _Nonnull)folder completionHandler:(void (^ _Nullable)(void))completionHandler;
- (void)copyTorrentFileTo:(NSString* _Nonnull)path;

@property(nonatomic, readonly) BOOL alertForRemainingDiskSpace;
- (BOOL)alertForRemainingDiskSpaceBypassThrottle:(BOOL)bypass;

@property(nonatomic, readonly) NSImage* _Nonnull icon;
/// Subtitle for multi-file media torrents (e.g., "x8" for 8 video files). Nil for non-media or single file.
@property(nonatomic, readonly) NSString* _Nullable iconSubtitle;

/// Array of playable media files. Each entry is a dictionary with keys:
/// - "index": NSNumber file index
/// - "name": NSString humanized display name (e.g., "E5" for episodes)
/// - "path": NSString file path on disk (nil if not downloaded)
/// Only includes files that are video/audio and exist on disk.
@property(nonatomic, readonly) NSArray<NSDictionary*>* _Nonnull playableFiles;
/// Best item to play from playableFiles: prefers .cue, then first with progress > 0, then first. Nil if list empty.
- (NSDictionary* _Nullable)preferredPlayableItemFromList:(NSArray<NSDictionary*>* _Nonnull)playableFiles;

/// Returns YES if torrent has any playable media files on disk.
@property(nonatomic, readonly) BOOL hasPlayableMedia;
/// YES when file-based audio is represented entirely by .cue+companion pairs (one playable entry per pair).
- (BOOL)isFileBasedAudioCueBased;

/// Returns detected media category: "video", "audio", "books", "software", "adult" (video with adult heuristic), or nil if none detected.
/// Used for auto-assigning torrents to groups based on content type.
@property(nonatomic, readonly) NSString* _Nullable detectedMediaCategory;

/// Returns detected media category for a specific file index.
- (NSString* _Nullable)mediaCategoryForFile:(NSUInteger)index;
/// YES when ext is a known video file extension. Used for play button ETA < duration visibility.
+ (BOOL)isVideoFileExtension:(NSString* _Nullable)ext;

/// YES if video at path is unwatched in IINA (no watch_later file and not in IINA playback history). Existence-only check; we do not parse watch_later contents. Used for tooltip/behavior; play button is drawn black-ish.
- (BOOL)iinaUnwatchedForVideoPath:(NSString* _Nonnull)path;
/// Invalidates IINA watch cache for path (call after user plays file so next show reflects IINA state).
+ (void)invalidateIINAWatchCacheForPath:(NSString* _Nonnull)path;

/// Cached height for play buttons view (calculated by TorrentTableView).
@property(nonatomic) CGFloat cachedPlayButtonsHeight;
/// Cached width used for play buttons layout (calculated by TorrentTableView).
@property(nonatomic) CGFloat cachedPlayButtonsWidth;
/// Cached play button state (title/visibility) for UI rendering.
@property(nonatomic, copy) NSArray<NSDictionary*>* _Nullable cachedPlayButtonState;
/// Lookup by file index or folder path for O(1) play-state entry access.
@property(nonatomic, copy) NSDictionary<NSNumber*, NSMutableDictionary*>* _Nullable cachedPlayButtonStateByIndex;
@property(nonatomic, copy) NSDictionary<NSString*, NSMutableDictionary*>* _Nullable cachedPlayButtonStateByFolder;
/// Cached source items for play button state.
@property(nonatomic, copy) NSArray<NSDictionary*>* _Nullable cachedPlayButtonSource;
/// Cached play button layout (season headers + items).
@property(nonatomic, copy) NSArray<NSDictionary*>* _Nullable cachedPlayButtonLayout;
/// Cached stats generation for play button progress.
@property(nonatomic) NSUInteger cachedPlayButtonProgressGeneration;
/// Cached stats generation for play menu.
@property(nonatomic) NSUInteger cachedPlayMenuGeneration;

/// Returns current file progress (0.0-1.0) for a file index.
- (CGFloat)fileProgressForIndex:(NSUInteger)index;
/// Returns total size in bytes for a file index.
- (uint64_t)fileSizeForIndex:(NSUInteger)index;

/// Returns consecutive progress for a folder (disc or album).
- (CGFloat)folderConsecutiveProgress:(NSString* _Nonnull)folder;
/// Returns consecutive progress for the first media file in a folder.
- (CGFloat)folderFirstMediaProgress:(NSString* _Nonnull)folder;
/// Invalidates file/folder progress caches so next progress read fetches from libtransmission (e.g. when UI refresh runs without updateTorrents).
- (void)invalidateFileProgressCache;
/// Returns file indexes for a folder if cached.
- (NSIndexSet* _Nullable)fileIndexesForFolder:(NSString* _Nonnull)folder;

@property(nonatomic, readonly) NSString* _Nonnull name;
@property(nonatomic, readonly) NSString* _Nonnull displayName;
@property(nonatomic, getter=isFolder, readonly) BOOL folder;
@property(nonatomic, readonly) uint64_t size;
@property(nonatomic, readonly) uint64_t sizeLeft;

@property(nonatomic, readonly) NSMutableArray* _Nonnull allTrackerStats;
@property(nonatomic, readonly) NSArray<NSString*>* _Nonnull allTrackersFlat; //used by GroupRules
- (BOOL)addTrackerToNewTier:(NSString* _Nonnull)tracker;
- (void)removeTrackers:(NSSet* _Nonnull)trackers;

@property(nonatomic, readonly) NSString* _Nonnull comment;
@property(nonatomic, readonly) NSURL* _Nullable commentURL;
@property(nonatomic, readonly) NSString* _Nonnull creator;
@property(nonatomic, readonly) NSDate* _Nonnull dateCreated;

@property(nonatomic, readonly) NSInteger pieceSize;
@property(nonatomic, readonly) NSInteger pieceCount;
@property(nonatomic, readonly) NSString* _Nonnull hashString;
@property(nonatomic, readonly) BOOL privateTorrent;

@property(nonatomic, readonly) NSString* _Nonnull torrentLocation;
@property(nonatomic, readonly) NSString* _Nonnull dataLocation;
/// Returns YES when none of the torrent's files exist on disk.
@property(nonatomic, readonly) BOOL allFilesMissing;
/// Returns YES when every file in the torrent exists under dir (or dir/name.part), using tr_torrentFile names.
- (BOOL)allFilesExistAtPath:(NSString* _Nonnull)dir;
@property(nonatomic, readonly) NSString* _Nullable lastKnownDataLocation;
- (NSString* _Nullable)fileLocation:(FileListNode* _Nonnull)node;
/// Path to open for this file/folder (prefers .cue for audio/album). Nil if location unknown.
- (NSString* _Nullable)pathToOpenForFileNode:(FileListNode* _Nonnull)node;
/// Path to open for an audio path: .cue path if companion exists, else path. Used for double-click and play.
- (NSString* _Nonnull)pathToOpenForAudioPath:(NSString* _Nonnull)path;
/// Path that would be opened for this playable item (e.g. .cue when present for audio). Used by play menu and play action.
- (NSString* _Nonnull)pathToOpenForPlayableItem:(NSDictionary* _Nonnull)item;
/// Same as pathToOpenForPlayableItem but returns nil if the path does not exist on disk. Use for play actions to avoid "Cannot open stream".
- (NSString* _Nullable)pathToOpenForPlayableItemIfExists:(NSDictionary* _Nonnull)item;
/// Path extension of a playable item (from item[@"path"] or item[@"originalExt"]). Nil if none.
- (NSString* _Nullable)pathExtensionOfPlayableItem:(NSDictionary* _Nonnull)item;
/// YES when this playable item should display as album (CUE) rather than single track. Single source for icon and play menu.
- (BOOL)playableItemOpensAsCueAlbum:(NSDictionary* _Nonnull)item;
/// Display name for play menu; should reflect the file that is opened (e.g. .cue when present).
- (NSString* _Nonnull)displayNameForPlayableItem:(NSDictionary* _Nonnull)item;

// Returns .cue file path for a given audio file path, or nil if no matching .cue file found
- (NSString* _Nullable)cueFilePathForAudioPath:(NSString* _Nonnull)audioPath;
/// Counts audio files and CUE files. Used for icon subtitle and icon selection (tracks > cues → audios).
- (void)audioAndCueCount:(NSUInteger* _Nonnull)outAudioCount cueCount:(NSUInteger* _Nonnull)outCueCount;

// Returns .cue file path for a given folder, or nil if no .cue file found in the folder
- (NSString* _Nullable)cueFilePathForFolder:(NSString* _Nonnull)folder;
/// Path to open for folder: .cue if .cue count >= audio count, else folder path. Implemented in Torrent+PathResolution.mm.
- (NSString* _Nullable)pathToOpenForFolder:(NSString* _Nonnull)folder;

// Returns the path to show in tooltip (prefers .cue file if available for audio files or album folders)
- (NSString* _Nullable)tooltipPathForItemPath:(NSString* _Nonnull)path type:(NSString* _Nonnull)type folder:(NSString* _Nonnull)folder;
/// Resolves path to absolute (handles relative paths, symlinks). Implemented in Torrent+PathResolution.mm.
- (NSString* _Nullable)resolvePathInTorrent:(NSString* _Nonnull)path;

/// Returns self. Used as NSSortDescriptor key so comparator receives Torrent objects, not key-path values.
@property(nonatomic, readonly) Torrent* _Nonnull selfForSorting;

/// YES if every string in strings appears in tracker list (byTracker) or in name/playable titles (includePlayableTitles). Used by filter bar search.
- (BOOL)matchesSearchStrings:(NSArray<NSString*>* _Nonnull)strings
                   byTracker:(BOOL)byTracker
       includePlayableTitles:(BOOL)includePlayableTitles;
/// Count of search strings that appear (0..strings.count). Used to sort filtered list by most matched first.
- (NSUInteger)searchMatchScoreForStrings:(NSArray<NSString*>* _Nonnull)strings
                               byTracker:(BOOL)byTracker
                   includePlayableTitles:(BOOL)includePlayableTitles;

/// Open/play count (double-click, play menu, content buttons). Key: hash|f<index> or hash|d<folder>.
- (void)recordOpenForFileNode:(FileListNode* _Nonnull)node;
- (void)recordOpenForPlayableItem:(NSDictionary* _Nonnull)item;
- (NSUInteger)openCountForFileNode:(FileListNode* _Nonnull)node;
- (NSUInteger)openCountForPlayableItem:(NSDictionary* _Nonnull)item;
/// "Played: N" for video/audio, "Opened: N" for other, nil when count is 0.
- (NSString* _Nullable)openCountLabelForFileNode:(FileListNode* _Nonnull)node;
- (NSString* _Nullable)openCountLabelForPlayableItem:(NSDictionary* _Nonnull)item;

- (void)renameTorrent:(NSString* _Nonnull)newName completionHandler:(void (^ _Nullable)(BOOL didRename))completionHandler;
- (void)renameFileNode:(FileListNode* _Nonnull)node
              withName:(NSString* _Nonnull)newName
     completionHandler:(void (^ _Nullable)(BOOL didRename))completionHandler;

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
@property(nonatomic, readonly) NSString* _Nullable errorMessage;
@property(nonatomic, getter=isPausedForDiskSpace, readonly) BOOL pausedForDiskSpace;
@property(nonatomic, readonly) uint64_t diskSpaceNeeded;
@property(nonatomic, readonly) uint64_t diskSpaceAvailable;
@property(nonatomic, readonly) uint64_t diskSpaceTotal;
@property(nonatomic, readonly) BOOL diskSpaceDialogShown;
@property(nonatomic) BOOL fDiskSpaceDialogShown;

@property(nonatomic, readonly) NSNumber* _Nullable volumeIdentifier;

@property(nonatomic, readonly) uint64_t totalTorrentDiskUsage;
@property(nonatomic, readonly) uint64_t totalTorrentDiskNeeded;

- (uint64_t)totalTorrentDiskUsageOnVolume:(NSNumber* _Nullable)volumeID;
- (uint64_t)totalTorrentDiskNeededOnVolume:(NSNumber* _Nullable)volumeID group:(NSInteger)groupValue;

@property(nonatomic, readonly) NSArray<NSDictionary*>* _Nonnull peers;

@property(nonatomic, readonly) NSUInteger webSeedCount;
@property(nonatomic, readonly) NSArray<NSDictionary*>* _Nonnull webSeeds;

@property(nonatomic, readonly) NSString* _Nonnull progressString;
@property(nonatomic, readonly) NSString* _Nonnull statusString;
@property(nonatomic, readonly) NSString* _Nonnull shortStatusString;
@property(nonatomic, readonly) NSString* _Nonnull remainingTimeString;
@property(nonatomic, readonly) NSUInteger statsGeneration;

@property(nonatomic) NSString* _Nullable fCachedHumanReadableTitle;

@property(nonatomic, readonly) NSString* _Nonnull stateString;
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
- (void)checkGroupValueForRemoval:(NSNotification* _Nonnull)notification;

@property(nonatomic, readonly) NSArray<FileListNode*>* _Nonnull fileList;
@property(nonatomic, readonly) NSArray<FileListNode*>* _Nonnull flatFileList;
@property(nonatomic, readonly) NSUInteger fileCount;

//methods require fileStats to have been updated recently to be accurate
- (CGFloat)fileProgress:(FileListNode* _Nonnull)node;
- (BOOL)canChangeDownloadCheckForFile:(NSUInteger)index;
- (BOOL)canChangeDownloadCheckForFiles:(NSIndexSet* _Nonnull)indexSet;
- (NSControlStateValue)checkForFiles:(NSIndexSet* _Nonnull)indexSet;
- (void)setFileCheckState:(NSControlStateValue)state forIndexes:(NSIndexSet* _Nonnull)indexSet;
- (void)setFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet* _Nonnull)indexSet;
- (BOOL)hasFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet* _Nonnull)indexSet;
- (NSSet* _Nonnull)filePrioritiesForIndexes:(NSIndexSet* _Nonnull)indexSet;

@property(nonatomic, readonly) NSDate* _Nonnull dateAdded;

/// Size in bytes of the torrent data selected for download
@property(nonatomic, readonly) uint64_t sizeWhenDone;
@property(nonatomic, readonly) NSDate* _Nullable dateCompleted;
@property(nonatomic, readonly) NSDate* _Nonnull dateActivity;
@property(nonatomic, readonly) NSDate* _Nonnull dateActivityOrAdd;
@property(nonatomic, readonly) NSDate* _Nullable dateLastPlayed;

@property(nonatomic, readonly) NSInteger secondsDownloading;
@property(nonatomic, readonly) NSInteger secondsSeeding;

@property(nonatomic, readonly) NSInteger stalledMinutes;
/// True if the torrent is running, but has been idle for long enough to be considered stalled.
@property(nonatomic, getter=isStalled, readonly) BOOL stalled;

- (void)updateTimeMachineExclude;

@property(nonatomic, readonly) NSInteger stateSortKey;
@property(nonatomic, readonly) NSString* _Nonnull trackerSortKey;

@property(nonatomic, readonly) tr_torrent* _Nonnull torrentStruct;

// Tracks whether we've verified partial data before resuming in this session
@property(nonatomic) BOOL fVerifiedOnResume;

/// Tracks file indexes that were played in the current session.
@property(nonatomic, readonly) NSMutableIndexSet* _Nonnull playedFiles;

NS_ASSUME_NONNULL_END

@end
