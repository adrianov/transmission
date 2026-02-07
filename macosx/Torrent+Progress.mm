// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (Progress)

#pragma mark - File and folder progress

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

- (void)invalidateFileProgressCache
{
    self.fProgressCacheGeneration = 0;
    self.fFileProgressCache = nil;
    self.fFolderProgressCache = nil;
    self.fFolderFirstMediaProgressCache = nil;
}

// Moved to Torrent+PathResolution.mm

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
        NSString* fileName = [NSString convertedStringFromCString:file.name];
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
        NSString* fileName = [NSString convertedStringFromCString:file.name];
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
        NSString* fileName = [NSString convertedStringFromCString:file.name];
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

// Moved to Torrent+PathResolution.mm

@end
#pragma clang diagnostic pop
