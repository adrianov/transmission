// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import "PlayButtonStateBuilder.h"
#import "PlayButtonTitleHelper.h"
#import "IINAWatchHelper.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"
#import "VideoDurationHelper.h"

static dispatch_queue_t iinaStateQueue()
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attrs = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.transmissionbt.playbutton.iina", attrs);
    });
    return queue;
}

@implementation PlayButtonStateBuilder

+ (void)enrichStateWithIinaUnwatched:(NSMutableArray<NSMutableDictionary*>*)state forTorrent:(Torrent*)torrent
{
    if (state.count == 0 || torrent == nil)
        return;

    NSMutableArray<NSDictionary*>* targets = [NSMutableArray array];
    for (NSMutableDictionary* entry in state)
    {
        if (![Torrent isVideoFileExtension:[torrent pathExtensionOfPlayableItem:entry]])
            continue;

        if (entry[@"iinaUnwatched"] != nil || [entry[@"iinaPending"] boolValue])
            continue;

        NSString* path = [entry[@"path"] isKindOfClass:[NSString class]] ? entry[@"path"] : nil;
        if (path.length == 0)
        {
            entry[@"iinaUnwatched"] = @NO;
            continue;
        }

        entry[@"iinaPending"] = @YES;
        [targets addObject:@{ @"entry" : entry, @"path" : path }];
    }

    if (targets.count == 0)
        return;

    __weak Torrent* weakTorrent = torrent;
    NSArray<NSString*>* paths = [targets valueForKey:@"path"];
    dispatch_async(iinaStateQueue(), ^{
        NSArray<NSNumber*>* values = [IINAWatchHelper unwatchedForVideoPaths:paths];

        dispatch_async(dispatch_get_main_queue(), ^{
            Torrent* strongTorrent = weakTorrent;
            if (!strongTorrent || strongTorrent.cachedPlayButtonState != state)
                return;

            BOOL changed = NO;
            for (NSUInteger i = 0; i < targets.count; ++i)
            {
                NSMutableDictionary* entry = targets[i][@"entry"];
                NSNumber* newValue = values[i];
                NSNumber* oldValue = entry[@"iinaUnwatched"];
                [entry removeObjectForKey:@"iinaPending"];
                if (oldValue == nil || oldValue.boolValue != newValue.boolValue)
                {
                    entry[@"iinaUnwatched"] = newValue;
                    changed = YES;
                }
            }

            if (changed)
            {
                [NSNotificationCenter.defaultCenter postNotificationName:kIINAWatchCacheDidUpdateNotification
                                                                  object:strongTorrent
                                                                userInfo:@{ @"refreshOnly" : @YES }];
            }
        });
    });
}

static void setStateLookups(Torrent* torrent, NSArray<NSMutableDictionary*>* state)
{
    if (!state || state.count == 0)
    {
        torrent.cachedPlayButtonStateByIndex = nil;
        torrent.cachedPlayButtonStateByFolder = nil;
        return;
    }
    NSMutableDictionary<NSNumber*, NSMutableDictionary*>* byIndex =
        [NSMutableDictionary dictionaryWithCapacity:state.count];
    NSMutableDictionary<NSString*, NSMutableDictionary*>* byFolder =
        [NSMutableDictionary dictionaryWithCapacity:state.count];
    for (NSMutableDictionary* entry in state)
    {
        NSNumber* idx = entry[@"index"];
        if (idx != nil)
            byIndex[idx] = entry;
        NSString* folder = [entry[@"folder"] isKindOfClass:[NSString class]] ? entry[@"folder"] : nil;
        if (folder.length > 0)
            byFolder[folder] = entry;
    }
    torrent.cachedPlayButtonStateByIndex = byIndex;
    torrent.cachedPlayButtonStateByFolder = byFolder;
}

+ (NSMutableArray<NSMutableDictionary*>*)stateForTorrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        torrent.cachedPlayButtonSource = nil;
        torrent.cachedPlayButtonState = nil;
        torrent.cachedPlayButtonLayout = nil;
        setStateLookups(torrent, nil);
        return nil;
    }

    BOOL isSameSource = [torrent.cachedPlayButtonSource isEqualToArray:playableFiles];
    if (!isSameSource)
    {
        torrent.cachedPlayButtonSource = playableFiles;
        torrent.cachedPlayButtonState = nil;
        torrent.cachedPlayButtonLayout = nil;
        setStateLookups(torrent, nil);
        torrent.cachedPlayButtonProgressGeneration = 0;
    }

    NSMutableArray<NSMutableDictionary*>* state = (NSMutableArray<NSMutableDictionary*>*)torrent.cachedPlayButtonState;
    if (!state)
    {
        state = [NSMutableArray arrayWithCapacity:playableFiles.count];
        BOOL singleItem = playableFiles.count == 1;

        for (NSDictionary* fileInfo in playableFiles)
        {
            NSMutableDictionary* entry = [fileInfo mutableCopy];
            NSString* type = entry[@"type"] ?: @"file";
            NSString* category = entry[@"category"];
            if (!category)
            {
                if ([type isEqualToString:@"file"] || [type hasPrefix:@"document"])
                    category = [torrent mediaCategoryForFile:[entry[@"index"] unsignedIntegerValue]];
                else
                    category = ([type isEqualToString:@"album"]) ? @"audio" : @"video";
                entry[@"category"] = category;
            }

            BOOL const itemIsBooks = [category isEqualToString:@"books"];
            BOOL const itemIsSoftware = [category isEqualToString:@"software"];

            if (singleItem)
            {
                NSString* baseTitle = itemIsBooks ? @"Read" : (itemIsSoftware ? @"Open" : @"Play");
                entry[@"baseTitle"] = baseTitle;
            }
            else
            {
                entry[@"baseTitle"] = entry[@"baseTitle"] ?: @"";
            }
            entry[@"title"] = entry[@"baseTitle"] ?: @"";
            CGFloat progress = 0.0;
            if (entry[@"index"])
                progress = [torrent fileProgressForIndex:[entry[@"index"] unsignedIntegerValue]];
            else
            {
                NSString* folder = entry[@"folder"];
                progress = folder.length > 0 ? [torrent folderConsecutiveProgress:folder] : 0.0;
            }
            entry[@"progress"] = @(progress);
            int progressPct = (int)floor(progress * 100);
            entry[@"progressPercent"] = @(progressPct);
            NSNumber* indexNum = entry[@"index"];
            BOOL wanted = indexNum ?
                ([torrent checkForFiles:[NSIndexSet indexSetWithIndex:indexNum.unsignedIntegerValue]] == NSControlStateValueOn) :
                YES;
            BOOL visible = playButtonIsItemVisible(type, progress, wanted);
            entry[@"visible"] = @(visible);
            [state addObject:entry];
        }
        playButtonApplyTitleStripping(state);
        // For single items playButtonApplyTitleStripping returns early; ensure strippedTitle is set
        if (state.count == 1)
            state[0][@"strippedTitle"] = state[0][@"title"] ?: @"";
        // Add progress percentage to display title (both single and multi items)
        for (NSMutableDictionary* e in state)
        {
            if (![e[@"visible"] boolValue] || [e[@"type"] hasPrefix:@"document"] || [e[@"progress"] doubleValue] >= 1.0 ||
                [e[@"progressPercent"] intValue] >= 100)
                continue;
            NSString* stripped = e[@"strippedTitle"] ?: @"";
            e[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", stripped, [e[@"progressPercent"] intValue]];
        }
        torrent.cachedPlayButtonState = state;
        state = (NSMutableArray<NSMutableDictionary*>*)torrent.cachedPlayButtonState;
        setStateLookups(torrent, state);
    }

    NSUInteger statsGeneration = torrent.statsGeneration;
    // When UI refresh runs without updateTorrents (e.g. fUpdatingUI skip), progress cache is stale; invalidate so we show current progress.
    if (torrent.cachedPlayButtonProgressGeneration == statsGeneration)
        [torrent invalidateFileProgressCache];

    BOOL visibilityChanged = NO;
    for (NSMutableDictionary* entry in state)
    {
        NSString* type = entry[@"type"] ?: @"file";
        NSNumber* index = entry[@"index"];
        CGFloat progress = [entry[@"progress"] doubleValue];
        BOOL wasVisible = [entry[@"visible"] boolValue];
        CGFloat newProgress = progress;
        if (index)
            newProgress = [torrent fileProgressForIndex:index.unsignedIntegerValue];
        else
        {
            NSString* folder = entry[@"folder"];
            newProgress = folder.length > 0 ? [torrent folderConsecutiveProgress:folder] : 0.0;
        }
        NSNumber* indexNum = entry[@"index"];
        BOOL wanted = indexNum ?
            ([torrent checkForFiles:[NSIndexSet indexSetWithIndex:indexNum.unsignedIntegerValue]] == NSControlStateValueOn) :
            YES;
        BOOL progressChanged = std::fabs(newProgress - progress) > 0.000001;
        if (progressChanged)
        {
            progress = newProgress;
            entry[@"progress"] = @(progress);
            int progressPct = (int)floor(progress * 100);
            entry[@"progressPercent"] = @(progressPct);
            BOOL visible = playButtonIsItemVisible(type, progress, wanted);
            BOOL isVideoFile = [Torrent isVideoFileExtension:[torrent pathExtensionOfPlayableItem:entry]];
            if (wasVisible && isVideoFile)
                visible = YES; // Do not re-evaluate ETA < duration once button is shown
            else
                visible = videoDisplayAllowedForItem(torrent, entry, progress, visible);
            entry[@"visible"] = @(visible);
            if (visible != wasVisible)
                visibilityChanged = YES;
            NSString* strippedTitle = entry[@"strippedTitle"] ?: entry[@"baseTitle"] ?: @"";
            NSString* title = strippedTitle;
            if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
                title = [NSString stringWithFormat:@"%@ (%d%%)", strippedTitle, progressPct];
            entry[@"title"] = title;
        }
        else
        {
            // ETA depends on download speed; re-evaluate video-file visibility so button appears when ETA < duration
            if (!wasVisible && progress < 1.0 && [Torrent isVideoFileExtension:[torrent pathExtensionOfPlayableItem:entry]])
            {
                int progressPct = [entry[@"progressPercent"] intValue];
                BOOL visible = playButtonIsItemVisible(type, progress, wanted);
                visible = videoDisplayAllowedForItem(torrent, entry, progress, visible);
                if (visible != wasVisible)
                {
                    entry[@"visible"] = @(visible);
                    visibilityChanged = YES;
                    NSString* strippedTitle = entry[@"strippedTitle"] ?: entry[@"baseTitle"] ?: @"";
                    entry[@"title"] = (visible && ![type hasPrefix:@"document"] && progressPct < 100) ?
                        [NSString stringWithFormat:@"%@ (%d%%)", strippedTitle, progressPct] : strippedTitle;
                }
            }
        }
    }

    if (visibilityChanged)
        torrent.cachedPlayButtonLayout = nil;

    [self enrichStateWithIinaUnwatched:state forTorrent:torrent];
    torrent.cachedPlayButtonProgressGeneration = statsGeneration;
    return state;
}

+ (NSArray<NSDictionary*>*)layoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state
{
    if (torrent.cachedPlayButtonLayout != nil)
        return torrent.cachedPlayButtonLayout;

    if (state.count == 0)
        return nil;

    NSMutableArray<NSDictionary*>* layout = [NSMutableArray array];
    if (state.count == 1)
    {
        [layout addObject:@{ @"kind" : @"item", @"item" : state[0] }];
        torrent.cachedPlayButtonLayout = layout;
        return layout;
    }

    BOOL anyVisible = NO;
    for (NSDictionary* entry in state)
    {
        if ([entry[@"visible"] boolValue])
        {
            anyVisible = YES;
            break;
        }
    }

    if (!anyVisible)
        return nil;

    NSMutableDictionary<NSNumber*, NSMutableArray<NSDictionary*>*>* seasonGroups = [NSMutableDictionary dictionary];
    for (NSDictionary* fileInfo in state)
    {
        id seasonValue = fileInfo[@"season"];
        NSNumber* season = (seasonValue && seasonValue != [NSNull null]) ? seasonValue : @0;
        if (!seasonGroups[season])
            seasonGroups[season] = [NSMutableArray array];
        [seasonGroups[season] addObject:fileInfo];
    }

    NSArray<NSNumber*>* sortedSeasons = [seasonGroups.allKeys sortedArrayUsingSelector:@selector(compare:)];
    BOOL hasMultipleSeasons = sortedSeasons.count > 1;
    NSUInteger totalFilesShown = 0;
    NSUInteger const maxFiles = 1000;

    for (NSNumber* season in sortedSeasons)
    {
        if (totalFilesShown >= maxFiles)
            break;

        NSArray<NSDictionary*>* filesInSeason = seasonGroups[season];

        if (hasMultipleSeasons && season.integerValue > 0)
            [layout addObject:@{ @"kind" : @"header", @"title" : [NSString stringWithFormat:@"Season %@:", season] }];

        for (NSDictionary* fileInfo in filesInSeason)
        {
            if (totalFilesShown >= maxFiles)
                break;
            if (![fileInfo[@"visible"] boolValue])
                continue;
            [layout addObject:@{ @"kind" : @"item", @"item" : fileInfo }];
            totalFilesShown++;
        }
    }

    torrent.cachedPlayButtonLayout = layout;
    return layout;
}

@end
