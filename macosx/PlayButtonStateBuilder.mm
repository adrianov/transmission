// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import "PlayButtonStateBuilder.h"
#import "Torrent.h"

static NSDictionary* stateAndLayoutFromSnapshotImpl(NSArray<NSDictionary*>* snapshot)
{
    if (snapshot.count == 0)
        return @{@"state" : [NSMutableArray array], @"layout" : @[]};
    NSMutableArray<NSMutableDictionary*>* state = [NSMutableArray arrayWithCapacity:snapshot.count];
    for (NSDictionary* fileInfo in snapshot)
    {
        NSMutableDictionary* entry = [fileInfo mutableCopy];
        NSString* type = entry[@"type"] ?: @"file";
        CGFloat progress = [entry[@"progress"] doubleValue];
        BOOL wanted = [entry[@"wanted"] boolValue];
        int progressPct = (int)floor(progress * 100);
        entry[@"progressPercent"] = @(progressPct);
        BOOL visible = [type hasPrefix:@"document"] ? (progress >= 1.0) : (progress > 0.000001 && (wanted || progress >= 1.0));
        entry[@"visible"] = @(visible);
        entry[@"title"] = entry[@"baseTitle"] ?: @"";
        if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
            entry[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", entry[@"baseTitle"], progressPct];
        [state addObject:entry];
    }
    if (state.count == 0)
        return @{@"state" : state, @"layout" : @[]};
    if (state.count == 1)
        return @{@"state" : state, @"layout" : @[ @{ @"kind" : @"item", @"item" : state[0] } ]};
    BOOL anyVisible = NO;
    for (NSDictionary* e in state)
    {
        if ([e[@"visible"] boolValue])
        {
            anyVisible = YES;
            break;
        }
    }
    if (!anyVisible)
        return @{@"state" : state, @"layout" : @[]};
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
    NSMutableArray<NSDictionary*>* layout = [NSMutableArray array];
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
            [layout addObject:@{ @"kind" : @"item", @"item" : fileInfo }];
            totalFilesShown++;
        }
    }
    return @{ @"state" : state, @"layout" : layout };
}

@implementation PlayButtonStateBuilder

+ (NSDictionary*)buildSnapshotForTorrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
        return nil;
    NSMutableArray<NSDictionary*>* snapshot = [NSMutableArray arrayWithCapacity:playableFiles.count];
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
        BOOL itemIsBooks = [category isEqualToString:@"books"];
        BOOL itemIsSoftware = [category isEqualToString:@"software"];
        if (singleItem)
            entry[@"baseTitle"] = itemIsBooks ? @"Read" : (itemIsSoftware ? @"Open" : @"Play");
        else
            entry[@"baseTitle"] = entry[@"baseTitle"] ?: @"";
        CGFloat progress = 0.0;
        if (entry[@"index"])
            progress = [torrent fileProgressForIndex:[entry[@"index"] unsignedIntegerValue]];
        else
            progress = [entry[@"folder"] length] > 0 ? [torrent folderConsecutiveProgress:entry[@"folder"]] : 0.0;
        entry[@"progress"] = @(progress);
        NSNumber* indexNum = entry[@"index"];
        BOOL wanted = indexNum ?
            ([torrent checkForFiles:[NSIndexSet indexSetWithIndex:indexNum.unsignedIntegerValue]] == NSControlStateValueOn) :
            YES;
        entry[@"wanted"] = @(wanted);
        [snapshot addObject:entry];
    }
    for (NSMutableDictionary* entry in snapshot)
    {
        NSString* category = entry[@"category"];
        if (![category isEqualToString:@"video"] && ![category isEqualToString:@"adult"])
            continue;
        NSString* pathToOpen = [torrent pathToOpenForPlayableItem:entry];
        BOOL const isUnwatched = (pathToOpen.length > 0) ? [torrent iinaUnwatchedForVideoPath:pathToOpen] : NO;
        entry[@"iinaUnwatched"] = @(isUnwatched);
    }
    return @{ @"snapshot" : snapshot, @"playableFiles" : playableFiles };
}

+ (NSDictionary*)stateAndLayoutFromSnapshot:(NSArray<NSDictionary*>*)snapshot
{
    return stateAndLayoutFromSnapshotImpl(snapshot);
}

+ (void)enrichStateWithIinaUnwatched:(NSMutableArray<NSMutableDictionary*>*)state forTorrent:(Torrent*)torrent
{
    for (NSMutableDictionary* entry in state)
    {
        NSString* category = entry[@"category"];
        if (![category isEqualToString:@"video"] && ![category isEqualToString:@"adult"])
            continue;
        NSString* pathToOpen = [torrent pathToOpenForPlayableItem:entry];
        BOOL const isUnwatched = (pathToOpen.length > 0) ? [torrent iinaUnwatchedForVideoPath:pathToOpen] : NO;
        entry[@"iinaUnwatched"] = @(isUnwatched);
    }
}

+ (NSMutableArray<NSMutableDictionary*>*)stateForTorrent:(Torrent*)torrent
{
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        torrent.cachedPlayButtonSource = nil;
        torrent.cachedPlayButtonState = nil;
        torrent.cachedPlayButtonLayout = nil;
        return nil;
    }

    BOOL isSameSource = [torrent.cachedPlayButtonSource isEqualToArray:playableFiles];
    if (!isSameSource)
    {
        torrent.cachedPlayButtonSource = playableFiles;
        torrent.cachedPlayButtonState = nil;
        torrent.cachedPlayButtonLayout = nil;
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
            BOOL visible = [type hasPrefix:@"document"] ? (progress >= 1.0) : (progress > 0.000001 && (wanted || progress >= 1.0));
            entry[@"visible"] = @(visible);
            if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
                entry[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", entry[@"baseTitle"], progressPct];
            // IINA watch-later: iinaUnwatched → green button; watched or no path → gray. Needs read access to IINA watch_later folder.
            if ([category isEqualToString:@"video"] || [category isEqualToString:@"adult"])
            {
                NSString* pathToOpen = [torrent pathToOpenForPlayableItem:entry];
                BOOL const isUnwatched = (pathToOpen.length > 0) ? [torrent iinaUnwatchedForVideoPath:pathToOpen] : NO;
                entry[@"iinaUnwatched"] = @(isUnwatched);
            }
            [state addObject:entry];
        }
        torrent.cachedPlayButtonState = state;
    }

    NSUInteger statsGeneration = torrent.statsGeneration;
    if (torrent.cachedPlayButtonProgressGeneration == statsGeneration)
    {
        [self enrichStateWithIinaUnwatched:state forTorrent:torrent];
        return state;
    }

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
        if (std::fabs(newProgress - progress) > 0.000001)
        {
            progress = newProgress;
            entry[@"progress"] = @(progress);
            int progressPct = (int)floor(progress * 100);
            entry[@"progressPercent"] = @(progressPct);
            NSNumber* indexNum = entry[@"index"];
            BOOL wanted = indexNum ?
                ([torrent checkForFiles:[NSIndexSet indexSetWithIndex:indexNum.unsignedIntegerValue]] == NSControlStateValueOn) :
                YES;
            BOOL visible = [type hasPrefix:@"document"] ? (progress >= 1.0) : (progress > 0.000001 && (wanted || progress >= 1.0));
            entry[@"visible"] = @(visible);
            if (visible != wasVisible)
                visibilityChanged = YES;
            NSString* baseTitle = entry[@"baseTitle"] ?: @"";
            NSString* title = baseTitle;
            if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
                title = [NSString stringWithFormat:@"%@ (%d%%)", baseTitle, progressPct];
            entry[@"title"] = title;
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
            [layout addObject:@{ @"kind" : @"item", @"item" : fileInfo }];
            totalFilesShown++;
        }
    }

    torrent.cachedPlayButtonLayout = layout;
    return layout;
}

@end
