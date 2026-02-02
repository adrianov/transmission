// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "Torrent.h"

@class FileListNode;

extern NSSet<NSString*>* sVideoExtensions;
extern NSSet<NSString*>* sAudioExtensions;
extern NSSet<NSString*>* sBookExtensions;
extern NSSet<NSString*>* sSoftwareExtensions;

/// Media type for folder torrents (used internally for playable and icon subtitle).
typedef NS_ENUM(NSInteger, TorrentMediaType) {
    TorrentMediaTypeNone = 0,
    TorrentMediaTypeVideo,
    TorrentMediaTypeAudio,
    TorrentMediaTypeBooks,
    TorrentMediaTypeSoftware
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

- (void)buildFolderToFilesCache:(NSSet<NSString*>*)folders;
- (void)detectMediaType;

/// Call once before using sVideoExtensions etc. (Torrent+MediaType, playable, media category).
+ (void)ensureMediaExtensionSets;
/// Stripped display titles for a group (2+ items). Single title returned as-is.
+ (NSArray<NSString*>*)displayTitlesByStrippingCommonPrefixSuffix:(NSArray<NSString*>*)titles;

@end

@interface Torrent (Books)
- (NSString*)preferredBookPathOutExt:(NSString**)outExt;
- (NSImage*)iconForBookAtPath:(NSString*)path extension:(NSString*)ext isComplete:(BOOL)complete;
@end

@interface Torrent (FileList)
- (void)createFileList;
- (void)insertPathForComponents:(NSArray<NSString*>*)components
             withComponentIndex:(NSUInteger)componentIndex
                      forParent:(FileListNode*)parent
                       fileSize:(uint64_t)size
                          index:(NSInteger)index
                       flatList:(NSMutableArray<FileListNode*>*)flatFileList;
- (void)sortFileList:(NSMutableArray<FileListNode*>*)fileNodes;
@end
