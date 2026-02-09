// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

/// Centralized path resolution service for torrent files and folders.
/// Handles: folder matching, CUE associations, path normalization for spaces in names.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (PathResolution)

#pragma mark - Folder Path Matching

/// Returns YES if fileName belongs to folder (handles spaces in folder names correctly).
/// Folder paths must match file.name prefix exactly, followed by '/' or end-of-string.
- (BOOL)fileName:(NSString*)fileName belongsToFolder:(NSString*)folder
{
    if (!fileName || !folder || folder.length == 0)
        return NO;
    return [fileName hasPrefix:folder] && (fileName.length == folder.length || [fileName characterAtIndex:folder.length] == '/');
}

/// Returns file indexes for a folder by scanning all files.
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

/// Builds cache mapping folders to their file indices (for fast progress lookups).
/// Folder keys must match torrent file paths exactly (do not trim); paths with spaces in names rely on this.
/// Iterates folders by length descending so the most specific (longest) folder wins when one path is a prefix of another.
- (void)buildFolderToFilesCache:(NSSet<NSString*>*)folders
{
    NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* cache = [NSMutableDictionary dictionary];

    for (NSString* folder in folders)
    {
        cache[folder] = [NSMutableArray array];
    }

    NSArray<NSString*>* foldersByLength = [folders.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
        if (a.length != b.length)
            return a.length > b.length ? NSOrderedAscending : NSOrderedDescending;
        return [a localizedStandardCompare:b];
    }];

    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        if (!fileName)
            continue;

        for (NSString* folder in foldersByLength)
        {
            if ([self fileName:fileName belongsToFolder:folder])
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

#pragma mark - CUE File Resolution

/// Returns .cue file path for audio path, or nil if no matching .cue found.
/// Handles relative paths, spaces in names, and companion file matching.
- (NSString*)cueFilePathForAudioPath:(NSString*)audioPath
{
    static NSSet<NSString*>* cueCompanionExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cueCompanionExtensions = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv", @"cue" ]];
    });

    NSString* ext = audioPath.pathExtension.lowercaseString;
    if (![cueCompanionExtensions containsObject:ext])
        return nil;

    if ([ext isEqualToString:@"cue"])
    {
        return [self resolvePathInTorrent:audioPath];
    }

    NSString* relativePath = [self relativePathInTorrent:audioPath];
    if (!relativePath || relativePath.length == 0)
        relativePath = audioPath.lastPathComponent;

    NSString* baseName = relativePath.lastPathComponent.stringByDeletingPathExtension;
    NSString* directory = relativePath.stringByDeletingLastPathComponent;
    if (directory.length == 0 || [directory isEqualToString:@"."] || [directory isEqualToString:@"/"])
        directory = @"";

    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        NSString* fileExt = fileName.pathExtension.lowercaseString;

        if ([fileExt isEqualToString:@"cue"])
        {
            NSString* cueBaseName = fileName.lastPathComponent.stringByDeletingPathExtension;
            NSString* cueDirectory = fileName.stringByDeletingLastPathComponent;
            if (cueDirectory.length == 0 || [cueDirectory isEqualToString:@"."] || [cueDirectory isEqualToString:@"/"])
                cueDirectory = @"";

            if ([cueBaseName.lowercaseString isEqualToString:baseName.lowercaseString] && [cueDirectory isEqualToString:directory])
            {
                return [self.currentDirectory stringByAppendingPathComponent:fileName];
            }
        }
    }

    // Same folder, single CUE: when base names differ (e.g. Album.flac + Album 2005.cue), treat as album and open .cue
    NSMutableArray<NSString*>* cuePathsInDir = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        NSString* fileExt = fileName.pathExtension.lowercaseString;
        if (![fileExt isEqualToString:@"cue"])
            continue;
        NSString* fileDir = fileName.stringByDeletingLastPathComponent;
        if (fileDir.length == 0 || [fileDir isEqualToString:@"."] || [fileDir isEqualToString:@"/"])
            fileDir = @"";
        if ([fileDir isEqualToString:directory])
            [cuePathsInDir addObject:[self.currentDirectory stringByAppendingPathComponent:fileName]];
    }
    if (cuePathsInDir.count == 1)
        return cuePathsInDir.firstObject;

    return nil;
}

/// Returns .cue file path for folder, or nil if no .cue found.
- (NSString*)cueFilePathForFolder:(NSString*)folder
{
    if (folder.length == 0)
        return nil;

    NSIndexSet* fileIndexes = [self fileIndexesForFolder:folder];
    if (fileIndexes.count == 0)
        return nil;

    __block NSString* cuePath = nil;
    [fileIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)idx);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        if ([fileName.pathExtension.lowercaseString isEqualToString:@"cue"])
        {
            cuePath = [self.currentDirectory stringByAppendingPathComponent:fileName];
            *stop = YES;
        }
    }];

    return cuePath;
}

/// Path to open for folder: .cue if .cue count >= audio count, else folder path.
- (NSString*)pathToOpenForFolder:(NSString*)folder
{
    if (folder.length == 0)
        return nil;

    NSIndexSet* fileIndexes = [self fileIndexesForFolder:folder];
    if (fileIndexes.count == 0)
        return [self.currentDirectory stringByAppendingPathComponent:folder];

    static NSSet<NSString*>* audioExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExts = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv" ]];
    });

    __block NSUInteger cueCount = 0;
    __block NSUInteger audioCount = 0;
    __block NSString* firstCuePath = nil;
    [fileIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        (void)stop;
        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)idx);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        NSString* ext = fileName.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"cue"])
        {
            cueCount++;
            if (!firstCuePath)
                firstCuePath = [self.currentDirectory stringByAppendingPathComponent:fileName];
        }
        else if ([audioExts containsObject:ext])
        {
            audioCount++;
        }
    }];

    if (cueCount >= audioCount && firstCuePath)
        return firstCuePath;
    return [self.currentDirectory stringByAppendingPathComponent:folder];
}

/// Path to open for audio: .cue if companion exists, else path.
- (NSString*)pathToOpenForAudioPath:(NSString*)path
{
    if (!path || path.length == 0)
        return path;

    NSString* ext = path.pathExtension.lowercaseString;
    static NSSet<NSString*>* audioExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioExts = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv" ]];
    });

    if ([audioExts containsObject:ext])
    {
        NSString* cuePath = [self cueFilePathForAudioPath:path];
        if (cuePath.length > 0)
            return cuePath;
    }

    return path;
}

#pragma mark - Path Normalization

/// Converts absolute or relative path to relative path within torrent (strips currentDirectory prefix).
- (NSString*)relativePathInTorrent:(NSString*)path
{
    if (!path || path.length == 0)
        return nil;

    NSString* torrentDir = self.currentDirectory;
    if ([path hasPrefix:torrentDir])
    {
        NSString* relative = [path substringFromIndex:torrentDir.length];
        if ([relative hasPrefix:@"/"])
            relative = [relative substringFromIndex:1];
        return relative;
    }

    if (![path isAbsolutePath])
        return path;

    // Try to match by last component
    NSString* lastComponent = path.lastPathComponent;
    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        if ([fileName.lastPathComponent.lowercaseString isEqualToString:lastComponent.lowercaseString])
            return fileName;
    }

    return nil;
}

/// Resolves path to absolute path (handles relative paths, spaces, symlinks).
- (NSString*)resolvePathInTorrent:(NSString*)path
{
    if (!path || path.length == 0)
        return nil;

    NSString* relativePath = [self relativePathInTorrent:path];
    if (!relativePath)
        return [path isAbsolutePath] ? path : nil;

    NSString* absolutePath = [self.currentDirectory stringByAppendingPathComponent:relativePath];
    if ([NSFileManager.defaultManager fileExistsAtPath:absolutePath])
    {
        NSString* resolved = [absolutePath stringByResolvingSymlinksInPath];
        return resolved.length > 0 ? resolved : absolutePath;
    }

    return absolutePath;
}

/// Path to open for playable item only when that path exists on disk; nil otherwise. Use for play actions so we never pass missing paths to the player.
- (NSString*)pathToOpenForPlayableItemIfExists:(NSDictionary*)item
{
    NSString* path = [self pathToOpenForPlayableItem:item];
    if (!path || path.length == 0)
        return nil;
    NSString* resolved = [self resolvePathInTorrent:path];
    NSString* final = (resolved.length > 0) ? resolved : path;
    return [NSFileManager.defaultManager fileExistsAtPath:final] ? final : nil;
}

/// Returns tooltip path for item (prefers .cue for audio/album).
- (NSString*)tooltipPathForItemPath:(NSString*)path type:(NSString*)type folder:(NSString*)folder
{
    NSString* resultPath = path;

    if ([type isEqualToString:@"album"] && folder.length > 0)
    {
        NSString* pathToOpen = [self pathToOpenForFolder:folder];
        if (pathToOpen)
            resultPath = pathToOpen;
    }

    if (resultPath && resultPath.length > 0)
        resultPath = [self pathToOpenForAudioPath:resultPath];

    if (resultPath && resultPath.length > 0)
        resultPath = [self resolvePathInTorrent:resultPath];

    return resultPath ?: path;
}

@end
#pragma clang diagnostic pop
