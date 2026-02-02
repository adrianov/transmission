// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Torrent.h"
#import "TorrentPrivate.h"

NSSet<NSString*>* sVideoExtensions;
NSSet<NSString*>* sAudioExtensions;
NSSet<NSString*>* sBookExtensions;
NSSet<NSString*>* sSoftwareExtensions;
static dispatch_once_t sMediaExtensionsOnce;

static void initMediaExtensionSets(void)
{
    dispatch_once(&sMediaExtensionsOnce, ^{
        sVideoExtensions = [NSSet setWithArray:@[
            @"mkv", @"avi", @"mp4", @"mov", @"wmv", @"flv", @"webm", @"m4v",
            @"mpg", @"mpeg", @"ts", @"m2ts", @"vob", @"3gp", @"ogv"
        ]];
        sAudioExtensions = [NSSet setWithArray:@[
            @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape",
            @"alac", @"aiff", @"opus", @"wv"
        ]];
        sBookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
        sSoftwareExtensions = [NSSet setWithArray:@[
            @"exe", @"msi", @"dmg", @"iso", @"pkg", @"deb", @"rpm", @"appimage", @"apk", @"run"
        ]];
    });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (MediaType)

+ (void)ensureMediaExtensionSets
{
    initMediaExtensionSets();
}

/// Detects dominant media type (video or audio) in folder torrents.
/// Also detects DVD structure (VIDEO_TS folder with VOB files).
- (void)detectMediaType
{
    if (self.fMediaTypeDetected)
        return;
    self.fMediaTypeDetected = YES;

    if (!self.folder || self.magnet)
        return;

    [Torrent ensureMediaExtensionSets];
    NSMutableDictionary<NSString*, NSNumber*>* videoExtCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* audioExtCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* bookExtCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* softwareExtCounts = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*>* dvdDiscFolders = [NSMutableSet set];
    NSMutableSet<NSString*>* blurayDiscFolders = [NSMutableSet set];

    NSUInteger const count = self.fileCount;
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* lastComponent = fileName.lastPathComponent.lowercaseString;
        NSString* ext = fileName.pathExtension.lowercaseString;

        if ([lastComponent isEqualToString:@"video_ts.ifo"])
        {
            NSString* discFolder = fileName.stringByDeletingLastPathComponent;
            [dvdDiscFolders addObject:discFolder];
            continue;
        }

        if ([lastComponent isEqualToString:@"index.bdmv"])
        {
            NSString* bdmvFolder = fileName.stringByDeletingLastPathComponent;
            NSString* discFolder = bdmvFolder.stringByDeletingLastPathComponent;
            [blurayDiscFolders addObject:discFolder.length > 0 ? discFolder : bdmvFolder];
            continue;
        }

        if ([ext isEqualToString:@"vob"])
        {
            NSString* folder = fileName.stringByDeletingLastPathComponent;
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
                continue;
        }

        if ([ext isEqualToString:@"m2ts"])
        {
            NSRange bdmvRange = [fileName rangeOfString:@"/BDMV/" options:NSCaseInsensitiveSearch];
            if (bdmvRange.location != NSNotFound || [fileName.lowercaseString hasPrefix:@"bdmv/"])
                continue;
        }

        if ([sVideoExtensions containsObject:ext])
            videoExtCounts[ext] = @(videoExtCounts[ext].unsignedIntegerValue + 1);
        else if ([sAudioExtensions containsObject:ext])
            audioExtCounts[ext] = @(audioExtCounts[ext].unsignedIntegerValue + 1);
        else if ([sBookExtensions containsObject:ext])
            bookExtCounts[ext] = @(bookExtCounts[ext].unsignedIntegerValue + 1);
        else if ([sSoftwareExtensions containsObject:ext])
            softwareExtCounts[ext] = @(softwareExtCounts[ext].unsignedIntegerValue + 1);
    }

    NSMutableSet<NSString*>* albumFolders = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = @(file.name);
        NSString* ext = fileName.pathExtension.lowercaseString;
        if ([sAudioExtensions containsObject:ext])
        {
            NSString* parentFolder = fileName.stringByDeletingLastPathComponent;
            if (parentFolder.length > 0)
                [albumFolders addObject:parentFolder];
        }
    }

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

    NSUInteger videoCount = 0, audioCount = 0, bookCount = 0, softwareCount = 0;
    NSString *dominantVideoExt = nil, *dominantAudioExt = nil, *dominantBookExt = nil, *dominantSoftwareExt = nil;
    NSString* dominantRegisteredBookExt = nil;
    NSUInteger dominantVideoCount = 0, dominantAudioCount = 0, dominantBookCount = 0, dominantSoftwareCount = 0;
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
    for (NSString* ext in softwareExtCounts)
    {
        NSUInteger c = softwareExtCounts[ext].unsignedIntegerValue;
        softwareCount += c;
        if (c > dominantSoftwareCount)
        {
            dominantSoftwareCount = c;
            dominantSoftwareExt = ext;
        }
    }
    if (dominantRegisteredBookExt != nil)
        dominantBookExt = dominantRegisteredBookExt;

    if (videoCount >= audioCount && videoCount >= bookCount && videoCount >= softwareCount && videoCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeVideo;
        self.fMediaFileCount = videoCount;
        self.fMediaExtension = dominantVideoExt;
    }
    else if (audioCount >= bookCount && audioCount >= softwareCount && audioCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeAudio;
        self.fMediaFileCount = audioCount;
        self.fMediaExtension = dominantAudioExt;
        if (albumFolders.count > 1)
        {
            self.fIsAlbumCollection = YES;
            self.fFolderItems = albumFolders.allObjects;
            [self buildFolderToFilesCache:albumFolders];
        }
    }
    else if (bookCount >= softwareCount && bookCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeBooks;
        self.fMediaFileCount = bookCount;
        self.fMediaExtension = dominantBookExt;
    }
    else if (softwareCount >= 1)
    {
        self.fMediaType = TorrentMediaTypeSoftware;
        self.fMediaFileCount = softwareCount;
        self.fMediaExtension = dominantSoftwareExt;
    }
}

@end
#pragma clang diagnostic pop
