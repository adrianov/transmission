// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "Torrent.h"
#import "TorrentPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (CueTooltip)

- (NSString*)cueFilePathForAudioPath:(NSString*)audioPath
{
    static NSSet<NSString*>* cueCompanionExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cueCompanionExtensions = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv", @"cue" ]];
    });

    NSString* ext = audioPath.pathExtension.lowercaseString;
    if (![cueCompanionExtensions containsObject:ext])
    {
        return nil;
    }

    if ([ext isEqualToString:@"cue"])
    {
        NSString* torrentDir = self.currentDirectory;
        NSString* relativePath = nil;

        if ([audioPath hasPrefix:torrentDir])
        {
            relativePath = [audioPath substringFromIndex:torrentDir.length];
            if ([relativePath hasPrefix:@"/"])
            {
                relativePath = [relativePath substringFromIndex:1];
            }
        }
        else if (![audioPath isAbsolutePath])
        {
            relativePath = audioPath;
        }

        if (relativePath && relativePath.length > 0)
        {
            NSUInteger const count = self.fileCount;
            for (NSUInteger i = 0; i < count; i++)
            {
                auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)i);
                NSString* fileName = @(file.name);
                if ([fileName isEqualToString:relativePath] ||
                    [fileName.lastPathComponent.lowercaseString isEqualToString:relativePath.lastPathComponent.lowercaseString])
                {
                    return [self.currentDirectory stringByAppendingPathComponent:fileName];
                }
            }
        }

        if ([audioPath isAbsolutePath])
        {
            return audioPath;
        }

        return nil;
    }

    NSString* torrentDir = self.currentDirectory;
    NSString* relativePath = nil;

    if ([audioPath hasPrefix:torrentDir])
    {
        relativePath = [audioPath substringFromIndex:torrentDir.length];
        if ([relativePath hasPrefix:@"/"])
        {
            relativePath = [relativePath substringFromIndex:1];
        }
    }

    if (!relativePath || relativePath.length == 0)
    {
        NSString* lastComponent = audioPath.lastPathComponent;
        NSUInteger const count = self.fileCount;
        for (NSUInteger i = 0; i < count; i++)
        {
            auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)i);
            NSString* fileName = @(file.name);
            if ([fileName.lastPathComponent.lowercaseString isEqualToString:lastComponent.lowercaseString])
            {
                relativePath = fileName;
                break;
            }
        }
    }

    if (!relativePath || relativePath.length == 0)
    {
        relativePath = audioPath.lastPathComponent;
    }

    NSString* baseName = relativePath.lastPathComponent.stringByDeletingPathExtension;
    NSString* directory = relativePath.stringByDeletingLastPathComponent;
    if (directory.length == 0 || [directory isEqualToString:@"."] || [directory isEqualToString:@"/"])
    {
        directory = @"";
    }

    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* fileExt = fileName.pathExtension.lowercaseString;

        if ([fileExt isEqualToString:@"cue"])
        {
            NSString* cueBaseName = fileName.lastPathComponent.stringByDeletingPathExtension;
            NSString* cueDirectory = fileName.stringByDeletingLastPathComponent;
            if (cueDirectory.length == 0 || [cueDirectory isEqualToString:@"."] || [cueDirectory isEqualToString:@"/"])
            {
                cueDirectory = @"";
            }

            if ([cueBaseName.lowercaseString isEqualToString:baseName.lowercaseString] && [cueDirectory isEqualToString:directory])
            {
                return [self.currentDirectory stringByAppendingPathComponent:fileName];
            }
        }
    }

    return nil;
}

/// YES if the torrent has a .cue file in the same directory as the given path (full or relative). Used for album icon when .cue and audio have different base names.
- (BOOL)hasCueInSameDirectoryAsPath:(NSString*)path
{
    if (!path || path.length == 0)
        return NO;
    NSString* dir = nil;
    NSString* torrentDir = self.currentDirectory;
    if (torrentDir.length > 0 && [path hasPrefix:torrentDir])
    {
        NSString* rel = [path substringFromIndex:torrentDir.length];
        if ([rel hasPrefix:@"/"])
            rel = [rel substringFromIndex:1];
        dir = rel.stringByDeletingLastPathComponent;
    }
    else
        dir = path.stringByDeletingLastPathComponent;
    if (dir.length == 0 || [dir isEqualToString:@"."] || [dir isEqualToString:@"/"])
        dir = @"";
    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)i);
        NSString* fileName = @(file.name);
        if ([fileName.pathExtension.lowercaseString isEqualToString:@"cue"])
        {
            NSString* fileDir = fileName.stringByDeletingLastPathComponent;
            if (fileDir.length == 0 || [fileDir isEqualToString:@"."] || [fileDir isEqualToString:@"/"])
                fileDir = @"";
            if ([fileDir isEqualToString:dir])
                return YES;
        }
    }
    return NO;
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
            cuePath = [self.currentDirectory stringByAppendingPathComponent:fileName];
            *stop = YES;
        }
    }];

    return cuePath;
}

/// Path to open for a folder: .cue path if .cue count >= audio count, else folder path. Opens directory when 1 .cue and many audio.
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
        NSString* fileName = @(file.name);
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
    {
        if (![resultPath isAbsolutePath])
        {
            resultPath = [self.currentDirectory stringByAppendingPathComponent:resultPath];
        }

        if ([NSFileManager.defaultManager fileExistsAtPath:resultPath])
        {
            NSString* resolvedPath = [resultPath stringByResolvingSymlinksInPath];
            if (resolvedPath && resolvedPath.length > 0)
            {
                resultPath = resolvedPath;
            }
        }
    }

    return resultPath ?: path;
}

@end
#pragma clang diagnostic pop
