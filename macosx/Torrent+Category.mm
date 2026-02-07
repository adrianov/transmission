// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static NSString* const kAdultTrackerHost = @"pornolab.net";
static NSSet<NSString*>* sAdultKeywords;
static dispatch_once_t sAdultKeywordsOnce;

static void initAdultKeywords(void)
{
    dispatch_once(&sAdultKeywordsOnce, ^{
        sAdultKeywords = [NSSet
            setWithArray:
                @[ @"[18+]", @"[adult]", @"[porn]", @"[xxx]", @"nsfw", @"onlyfans", @"porn", @"pornhub", @"xxx", @"xvideos" ]];
    });
}

static BOOL containsAdultKeywords(NSString* text)
{
    if (text.length == 0)
        return NO;
    initAdultKeywords();
    NSString* lower = text.lowercaseString;
    for (NSString* keyword in sAdultKeywords)
    {
        if ([lower containsString:keyword])
            return YES;
    }
    return NO;
}

static BOOL hasAdultTracker(NSArray<NSString*>* trackerURLs)
{
    for (NSString* url in trackerURLs)
    {
        NSURL* u = [NSURL URLWithString:url];
        if (u.host && [u.host.lowercaseString isEqualToString:kAdultTrackerHost])
            return YES;
    }
    return NO;
}

static BOOL hasAdultSource(NSArray<NSString*>* trackerURLs, NSString* comment)
{
    if (hasAdultTracker(trackerURLs))
        return YES;
    if (comment.length > 0 && [comment.lowercaseString containsString:kAdultTrackerHost])
        return YES;
    return NO;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (Category)

- (BOOL)hasPlayableMedia
{
    if (self.magnet)
        return NO;
    if (self.folder)
    {
        [self detectMediaType];
        return self.fMediaType != TorrentMediaTypeNone;
    }
    [Torrent ensureMediaExtensionSets];
    NSString* ext = self.name.pathExtension.lowercaseString;
    return [sVideoExtensions containsObject:ext] || [sAudioExtensions containsObject:ext];
}

- (NSString*)mediaCategoryForFile:(NSUInteger)index
{
    [Torrent ensureMediaExtensionSets];
    auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)index);
    NSString* path = [NSString convertedStringFromCString:file.name];
    NSString* ext = path.pathExtension.lowercaseString;
    NSString* base = nil;
    if ([sVideoExtensions containsObject:ext])
        base = @"video";
    else if ([sAudioExtensions containsObject:ext])
        base = @"audio";
    else if ([sBookExtensions containsObject:ext])
        base = @"books";
    else if ([sSoftwareExtensions containsObject:ext])
        base = @"software";
    if (!base)
        return nil;
    if ([base isEqualToString:@"video"] && ([self isAdultTorrent] || containsAdultKeywords(path)))
        return @"adult";
    return base;
}

- (NSString*)baseMediaCategory
{
    if (self.magnet)
        return nil;
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
        case TorrentMediaTypeSoftware:
            return @"software";
        default:
            return nil;
        }
    }
    [Torrent ensureMediaExtensionSets];
    NSString* ext = self.name.pathExtension.lowercaseString;
    if ([sVideoExtensions containsObject:ext])
        return @"video";
    if ([sAudioExtensions containsObject:ext])
        return @"audio";
    if ([sBookExtensions containsObject:ext])
        return @"books";
    if ([sSoftwareExtensions containsObject:ext])
        return @"software";
    return nil;
}

- (BOOL)isAdultTorrent
{
    if (hasAdultSource(self.allTrackersFlat, self.comment))
        return YES;
    NSString* base = [self baseMediaCategory];
    if (![base isEqualToString:@"video"])
        return NO;
    NSString* combined = [NSString stringWithFormat:@"%@ %@", self.name ?: @"", self.comment ?: @""];
    return containsAdultKeywords(combined);
}

- (NSString*)detectedMediaCategory
{
    if (hasAdultSource(self.allTrackersFlat, self.comment))
        return @"adult";
    NSString* base = [self baseMediaCategory];
    if (!base)
        return nil;
    if ([base isEqualToString:@"video"] && [self isAdultTorrent])
        return @"adult";
    return base;
}

@end
#pragma clang diagnostic pop
