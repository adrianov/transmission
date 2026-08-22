// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <AppKit/AppKit.h>

#include <libtransmission/transmission.h>

@class FileListNode;
@class Torrent;

NS_ASSUME_NONNULL_BEGIN

/// Files, playable media, and play-button layout cache for a torrent.
@interface TorrentContent : NSObject

@property(nonatomic) CGFloat cachedPlayButtonsHeight;
@property(nonatomic) CGFloat cachedPlayButtonsWidth;
@property(nonatomic, copy, nullable) NSArray<NSDictionary*>* cachedPlayButtonState;
@property(nonatomic, copy, nullable) NSDictionary<NSNumber*, NSMutableDictionary*>* cachedPlayButtonStateByIndex;
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSMutableDictionary*>* cachedPlayButtonStateByFolder;
@property(nonatomic, copy, nullable) NSArray<NSDictionary*>* cachedPlayButtonSource;
@property(nonatomic, copy, nullable) NSArray<NSDictionary*>* cachedPlayButtonLayout;
@property(nonatomic) NSUInteger cachedPlayButtonProgressGeneration;
@property(nonatomic, copy, nullable) NSArray<NSDictionary*>* cachedPlayMenuLayout;

- (void)clearPlayButtonCache;

@end

@interface Torrent (Content)

@property(nonatomic, readonly) NSImage* icon;
@property(nonatomic, readonly, nullable) NSString* iconSubtitle;

@property(nonatomic, readonly) NSArray<NSDictionary*>* playableFiles;
- (nullable NSDictionary*)preferredPlayableItemFromList:(NSArray<NSDictionary*>*)playableFiles;
@property(nonatomic, readonly) BOOL hasPlayableMedia;
- (BOOL)isFileBasedAudioCueBased;

@property(nonatomic, readonly, nullable) NSString* detectedMediaCategory;
- (nullable NSString*)mediaCategoryForFile:(NSUInteger)index;
+ (BOOL)isVideoFileExtension:(nullable NSString*)ext;

- (BOOL)iinaUnwatchedForVideoPath:(NSString*)path;
+ (void)invalidateIINAWatchCacheForPath:(NSString*)path;

- (CGFloat)fileProgressForIndex:(NSUInteger)index;
- (uint64_t)fileSizeForIndex:(NSUInteger)index;
- (CGFloat)folderConsecutiveProgress:(NSString*)folder;
- (CGFloat)folderFirstMediaProgress:(NSString*)folder;
- (void)invalidateFileProgressCache;
- (nullable NSIndexSet*)fileIndexesForFolder:(NSString*)folder;

@property(nonatomic, readonly) BOOL allFilesMissing;
- (BOOL)allFilesExistAtPath:(NSString*)dir;
@property(nonatomic, readonly, nullable) NSString* lastKnownDataLocation;
- (nullable NSString*)fileLocation:(FileListNode*)node;
- (nullable NSString*)pathToOpenForFileNode:(FileListNode*)node;
- (NSString*)pathToOpenForAudioPath:(NSString*)path;
- (NSString*)pathToOpenForPlayableItem:(NSDictionary*)item;
- (nullable NSString*)pathToOpenForPlayableItemIfExists:(NSDictionary*)item;
- (nullable NSString*)pathExtensionOfPlayableItem:(NSDictionary*)item;
- (BOOL)playableItemOpensAsCueAlbum:(NSDictionary*)item;
- (NSString*)displayNameForPlayableItem:(NSDictionary*)item;

- (nullable NSString*)cueFilePathForAudioPath:(NSString*)audioPath;
- (void)audioAndCueCount:(NSUInteger*)outAudioCount cueCount:(NSUInteger*)outCueCount;
- (nullable NSArray<NSDictionary*>*)tracksForFolder:(NSString*)folder;
- (nullable NSString*)cueFilePathForFolder:(NSString*)folder;
- (nullable NSString*)pathToOpenForFolder:(NSString*)folder;
- (nullable NSString*)tooltipPathForItemPath:(NSString*)path type:(NSString*)type folder:(NSString*)folder;
- (nullable NSString*)resolvePathInTorrent:(NSString*)path;

- (BOOL)matchesSearchStrings:(NSArray<NSString*>*)strings
                   byTracker:(BOOL)byTracker
       includePlayableTitles:(BOOL)includePlayableTitles;
- (NSUInteger)searchMatchScoreForStrings:(NSArray<NSString*>*)strings
                               byTracker:(BOOL)byTracker
                   includePlayableTitles:(BOOL)includePlayableTitles;

- (void)recordOpenForFileNode:(FileListNode*)node;
- (void)recordOpenForPlayableItem:(NSDictionary*)item;
- (NSUInteger)openCountForFileNode:(FileListNode*)node;
- (NSUInteger)openCountForPlayableItem:(NSDictionary*)item;
- (nullable NSString*)openCountLabelForFileNode:(FileListNode*)node;
- (nullable NSString*)openCountLabelForPlayableItem:(NSDictionary*)item;

@property(nonatomic, readonly) BOOL alertForRemainingDiskSpace;
- (BOOL)alertForRemainingDiskSpaceBypassThrottle:(BOOL)bypass;
@property(nonatomic, getter=isPausedForDiskSpace, readonly) BOOL pausedForDiskSpace;
@property(nonatomic, readonly) uint64_t diskSpaceNeeded;
@property(nonatomic, readonly) uint64_t diskSpaceAvailable;
@property(nonatomic, readonly) uint64_t diskSpaceTotal;
@property(nonatomic) BOOL diskSpaceDialogShown;
@property(nonatomic, readonly, nullable) NSNumber* volumeIdentifier;
@property(nonatomic, readonly) uint64_t totalTorrentDiskUsage;
@property(nonatomic, readonly) uint64_t totalTorrentDiskNeeded;
- (uint64_t)totalTorrentDiskUsageOnVolume:(nullable NSNumber*)volumeID;
- (uint64_t)totalTorrentDiskNeededOnVolume:(nullable NSNumber*)volumeID group:(NSInteger)groupValue;

@property(nonatomic, readonly) NSArray<FileListNode*>* fileList;
@property(nonatomic, readonly) NSArray<FileListNode*>* flatFileList;
@property(nonatomic, readonly) NSUInteger fileCount;
- (CGFloat)fileProgress:(FileListNode*)node;
- (BOOL)canChangeDownloadCheckForFile:(NSUInteger)index;
- (BOOL)canChangeDownloadCheckForFiles:(NSIndexSet*)indexSet;
- (NSControlStateValue)checkForFiles:(NSIndexSet*)indexSet;
- (BOOL)fileIsWantedAtIndex:(NSUInteger)index;
- (void)setFileCheckState:(NSControlStateValue)state forIndexes:(NSIndexSet*)indexSet;
- (void)setFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet*)indexSet;
- (BOOL)hasFilePriority:(tr_priority_t)priority forIndexes:(NSIndexSet*)indexSet;
- (NSSet*)filePrioritiesForIndexes:(NSIndexSet*)indexSet;

@end

NS_ASSUME_NONNULL_END
