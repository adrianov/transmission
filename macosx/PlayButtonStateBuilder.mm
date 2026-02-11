// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <cmath>

#import "PlayButtonStateBuilder.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static CGFloat const kMinProgressToShowPlayButton = 0.01;

/// When multiple buttons share the same stripped title, prepend humanized parent directory and re-strip so labels are distinct (e.g. "Part 01 — Monte Cristo").
static void disambiguateDuplicateTitles(NSMutableArray<NSMutableDictionary*>* state, NSArray<NSNumber*>* seasons)
{
    if (state.count < 2)
        return;
    NSArray<NSString*>* titles = [state valueForKey:@"title"];
    NSCountedSet<NSString*>* counts = [NSCountedSet setWithArray:titles];
    BOOL anyDuplicate = NO;
    for (NSString* t in counts)
        if ([counts countForObject:t] > 1)
        {
            anyDuplicate = YES;
            break;
        }
    if (!anyDuplicate)
        return;
    for (NSUInteger i = 0; i < state.count; i++)
    {
        if ([counts countForObject:titles[i]] < 2)
            continue;
        NSMutableDictionary* e = state[i];
        NSString* path = e[@"path"];
        NSString* folder = e[@"folder"];
        NSString* parent = (path.length > 0) ? [path stringByDeletingLastPathComponent].lastPathComponent :
            (folder.length > 0 ? (folder.lastPathComponent ?: folder) : @"");
        if (parent.length == 0)
            continue;
        NSString* humanized = parent.humanReadableFileName;
        if (humanized.length == 0)
            continue;
        NSString* base = e[@"baseTitle"] ?: @"";
        e[@"baseTitle"] = [NSString stringWithFormat:@"%@ — %@", humanized, base];
    }
    NSArray<NSString*>* newTitles = [Torrent displayTitlesByStrippingCommonPrefixSuffix:[state valueForKey:@"baseTitle"] seasons:seasons];
    for (NSUInteger i = 0; i < state.count; i++)
    {
        if ([state[i][@"type"] isEqualToString:@"document-books"])
            state[i][@"title"] = state[i][@"baseTitle"] ?: @"";
        else
            state[i][@"title"] = newTitles[i];
    }
}

/// Determines if a playable item should be visible based on type, progress, and wanted state.
static BOOL isPlayableItemVisible(NSString* type, CGFloat progress, BOOL wanted)
{
    if ([type isEqualToString:@"album"])
        return YES;
    if ([type hasPrefix:@"document"])
        return progress >= 1.0;
    return progress >= kMinProgressToShowPlayButton && (wanted || progress >= 1.0);
}

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
        BOOL visible = isPlayableItemVisible(type, progress, wanted);
        entry[@"visible"] = @(visible);
        entry[@"title"] = entry[@"baseTitle"] ?: @"";
        if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
            entry[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", entry[@"baseTitle"], progressPct];
        [state addObject:entry];
    }
    // Strip common prefix/suffix for directory (folder) and episode (file) buttons; context menu uses same state titles.
    if (state.count >= 2)
    {
        NSArray<NSString*>* titles = [state valueForKey:@"baseTitle"];
        NSMutableArray<NSNumber*>* seasons = [NSMutableArray arrayWithCapacity:state.count];
        for (NSDictionary* e in state)
        {
            id s = e[@"season"];
            [seasons addObject:(s && s != [NSNull null]) ? s : @0];
        }
        NSArray<NSString*>* stripped = [Torrent displayTitlesByStrippingCommonPrefixSuffix:titles seasons:seasons];
        for (NSUInteger i = 0; i < state.count; i++)
        {
            // Regression: do not apply token-based strip to document-books; it over-strips (e.g. "In The Court Of The Crimson King..."
            // → "In" when mixed with audio tracks sharing tokens). See Torrent+Playable.mm playableFiles.
            if (![state[i][@"type"] isEqualToString:@"document-books"])
                state[i][@"title"] = stripped[i];
        }
        disambiguateDuplicateTitles(state, seasons);
        for (NSUInteger i = 0; i < state.count; i++)
        {
            NSMutableDictionary* e = state[i];
            if ([e[@"visible"] boolValue] && ![e[@"type"] hasPrefix:@"document"] && [e[@"progress"] doubleValue] < 1.0 &&
                [e[@"progressPercent"] intValue] < 100)
                e[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", e[@"title"], [e[@"progressPercent"] intValue]];
        }
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
            BOOL visible = isPlayableItemVisible(type, progress, wanted);
            entry[@"visible"] = @(visible);
            if (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100)
                entry[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", entry[@"baseTitle"], progressPct];
            // IINA watch_later + playback history: existence-only check (no parsing). iinaUnwatched → green; watched (file or in history) or no path → gray.
            if ([category isEqualToString:@"video"] || [category isEqualToString:@"adult"])
            {
                NSString* pathToOpen = [torrent pathToOpenForPlayableItem:entry];
                BOOL const isUnwatched = (pathToOpen.length > 0) ? [torrent iinaUnwatchedForVideoPath:pathToOpen] : NO;
                entry[@"iinaUnwatched"] = @(isUnwatched);
            }
            [state addObject:entry];
        }
        if (state.count >= 2)
        {
            NSArray<NSString*>* titles = [state valueForKey:@"baseTitle"];
            NSMutableArray<NSNumber*>* seasons = [NSMutableArray arrayWithCapacity:state.count];
            for (NSDictionary* e in state)
            {
                id s = e[@"season"];
                [seasons addObject:(s && s != [NSNull null]) ? s : @0];
            }
            NSArray<NSString*>* stripped = [Torrent displayTitlesByStrippingCommonPrefixSuffix:titles seasons:seasons];
            for (NSUInteger i = 0; i < state.count; i++)
            {
                if (![state[i][@"type"] isEqualToString:@"document-books"])
                    state[i][@"title"] = stripped[i];
            }
            disambiguateDuplicateTitles(state, seasons);
            for (NSMutableDictionary* e in state)
            {
                if ([e[@"visible"] boolValue] && ![e[@"type"] hasPrefix:@"document"] && [e[@"progress"] doubleValue] < 1.0 &&
                    [e[@"progressPercent"] intValue] < 100)
                    e[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", e[@"title"], [e[@"progressPercent"] intValue]];
            }
        }
        torrent.cachedPlayButtonState = state;
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
            BOOL visible = isPlayableItemVisible(type, progress, wanted);
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
    if (state.count >= 2)
    {
        NSArray<NSString*>* titles = [state valueForKey:@"baseTitle"];
        NSMutableArray<NSNumber*>* seasons = [NSMutableArray arrayWithCapacity:state.count];
        for (NSDictionary* e in state)
        {
            id s = e[@"season"];
            [seasons addObject:(s && s != [NSNull null]) ? s : @0];
        }
        NSArray<NSString*>* stripped = [Torrent displayTitlesByStrippingCommonPrefixSuffix:titles seasons:seasons];
        for (NSUInteger i = 0; i < state.count; i++)
        {
            if (![state[i][@"type"] isEqualToString:@"document-books"])
                state[i][@"title"] = stripped[i];
        }
        disambiguateDuplicateTitles(state, seasons);
        for (NSUInteger i = 0; i < state.count; i++)
        {
            NSMutableDictionary* e = state[i];
            NSString* displayTitle = e[@"title"];
            if ([e[@"visible"] boolValue] && ![e[@"type"] hasPrefix:@"document"] && [e[@"progress"] doubleValue] < 1.0 &&
                [e[@"progressPercent"] intValue] < 100)
                e[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", displayTitle, [e[@"progressPercent"] intValue]];
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
