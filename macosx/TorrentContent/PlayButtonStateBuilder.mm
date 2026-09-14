// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "IINAWatchHelper.h"
#import "PlayButtonEntryState.h"
#import "PlayButtonStateBuilder.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

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

/// Collects video entries that still need an IINA watched/unwatched lookup.
static NSArray<NSDictionary*>* playButtonIinaTargetsForState(NSArray<NSMutableDictionary*>* state, Torrent* torrent)
{
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
    return targets;
}

/// Applies IINA lookup results to the target entries, always clearing the pending marker.
/// Returns whether any view-visible value changed.
static BOOL playButtonApplyIinaValues(NSArray<NSDictionary*>* targets, NSArray<NSNumber*>* values)
{
    BOOL changed = NO;
    for (NSUInteger i = 0; i < targets.count; ++i)
    {
        NSMutableDictionary* entry = targets[i][@"entry"];
        NSNumber* oldValue = entry[@"iinaUnwatched"];
        [entry removeObjectForKey:@"iinaPending"];
        if (oldValue != nil && oldValue.boolValue == values[i].boolValue)
            continue;
        entry[@"iinaUnwatched"] = values[i];
        changed = YES;
    }
    return changed;
}

@implementation PlayButtonStateBuilder

+ (void)enrichStateWithIinaUnwatched:(NSMutableArray<NSMutableDictionary*>*)state forTorrent:(Torrent*)torrent
{
    if (state.count == 0 || torrent == nil)
        return;

    NSArray<NSDictionary*>* targets = playButtonIinaTargetsForState(state, torrent);
    if (targets.count == 0)
        return;

    __weak Torrent* weakTorrent = torrent;
    dispatch_async(iinaStateQueue(), ^{
        NSArray<NSNumber*>* values = [IINAWatchHelper unwatchedForVideoPaths:[targets valueForKey:@"path"]];

        dispatch_async(dispatch_get_main_queue(), ^{
            // Weak reads are safe to repeat here: the block runs on the main thread, where the
            // torrent cannot be deallocated mid-block.
            if (weakTorrent == nil || weakTorrent.content.cachedPlayButtonState != state)
                return;

            if (!playButtonApplyIinaValues(targets, values))
                return;

            weakTorrent.content.cachedPlayButtonIinaDirty = YES;
            [NSNotificationCenter.defaultCenter postNotificationName:kIINAWatchCacheDidUpdateNotification object:weakTorrent
                                                            userInfo:@{
                                                                @"refreshOnly" : @YES
                                                            }];
        });
    });
}

static void setStateLookups(Torrent* torrent, NSArray<NSMutableDictionary*>* state)
{
    if (!state || state.count == 0)
    {
        torrent.content.cachedPlayButtonStateByIndex = nil;
        torrent.content.cachedPlayButtonStateByFolder = nil;
        return;
    }
    NSMutableDictionary<NSNumber*, NSMutableDictionary*>* byIndex = [NSMutableDictionary dictionaryWithCapacity:state.count];
    NSMutableDictionary<NSString*, NSMutableDictionary*>* byFolder = [NSMutableDictionary dictionaryWithCapacity:state.count];
    for (NSMutableDictionary* entry in state)
    {
        NSNumber* idx = entry[@"index"];
        if (idx != nil)
            byIndex[idx] = entry;
        NSString* folder = [entry[@"folder"] isKindOfClass:[NSString class]] ? entry[@"folder"] : nil;
        if (folder.length > 0)
            byFolder[folder] = entry;
    }
    torrent.content.cachedPlayButtonStateByIndex = byIndex;
    torrent.content.cachedPlayButtonStateByFolder = byFolder;
}

/// Drops cached state/layout and lookups so the next stateForTorrent rebuilds; replaces the source
/// when sourceReplacement is given, and optionally resets the progress generation.
static void playButtonInvalidateStateCache(Torrent* torrent, NSArray<NSDictionary*>* sourceReplacement, BOOL resetGeneration)
{
    torrent.content.cachedPlayButtonSource = sourceReplacement;
    torrent.content.cachedPlayButtonState = nil;
    torrent.content.cachedPlayButtonLayout = nil;
    setStateLookups(torrent, nil);
    if (resetGeneration)
        torrent.content.cachedPlayButtonProgressGeneration = 0;
}

/// Returns the torrent's cached play-button state, rebuilding it from the playable files when absent.
/// Sets *stateWasBuilt when a rebuild happened.
+ (NSMutableArray<NSMutableDictionary*>*)cachedOrBuiltStateForPlayableFiles:(NSArray<NSDictionary*>*)playableFiles
                                                                    torrent:(Torrent*)torrent
                                                              stateWasBuilt:(BOOL*)stateWasBuilt
{
    NSMutableArray<NSMutableDictionary*>* state = (NSMutableArray<NSMutableDictionary*>*)torrent.content.cachedPlayButtonState;
    if (state != nil)
        return state;

    state = [NSMutableArray arrayWithCapacity:playableFiles.count];
    playButtonBuildStateForPlayableFiles(state, playableFiles, torrent);
    torrent.content.cachedPlayButtonState = state;
    setStateLookups(torrent, state);
    *stateWasBuilt = YES;
    return state;
}

+ (NSMutableArray<NSMutableDictionary*>*)stateForTorrent:(Torrent*)torrent
{
    return [self stateForTorrent:torrent changedOut:NULL];
}

/// Refreshes every entry against current progress; invalidates the layout when visibility flipped.
+ (BOOL)refreshState:(NSMutableArray<NSMutableDictionary*>*)state forTorrent:(Torrent*)torrent
{
    BOOL visibilityChanged = NO;
    BOOL changed = NO;
    for (NSMutableDictionary* entry in state)
        changed = playButtonRefreshEntry(entry, torrent, &visibilityChanged) || changed;
    if (visibilityChanged)
        torrent.content.cachedPlayButtonLayout = nil;
    return changed;
}

+ (NSMutableArray<NSMutableDictionary*>*)stateForTorrent:(Torrent*)torrent changedOut:(BOOL*)changedOut
{
    BOOL const iinaDirty = torrent.content.cachedPlayButtonIinaDirty;
    torrent.content.cachedPlayButtonIinaDirty = NO;
    NSArray<NSDictionary*>* playableFiles = torrent.playableFiles;
    if (playableFiles.count == 0)
    {
        playButtonInvalidateStateCache(torrent, nil, NO);
        if (changedOut)
            *changedOut = iinaDirty;
        return nil;
    }

    if (![torrent.content.cachedPlayButtonSource isEqualToArray:playableFiles])
        playButtonInvalidateStateCache(torrent, playableFiles, YES);

    BOOL stateWasBuilt = NO;
    NSMutableArray<NSMutableDictionary*>* state = [self cachedOrBuiltStateForPlayableFiles:playableFiles torrent:torrent
                                                                             stateWasBuilt:&stateWasBuilt];

    NSUInteger statsGeneration = torrent.statsGeneration;
    // When UI refresh runs without updateTorrents (e.g. fUpdatingUI skip), progress cache is stale; invalidate so we show current progress.
    if (torrent.content.cachedPlayButtonProgressGeneration == statsGeneration)
        [torrent invalidateFileProgressCache];

    BOOL changed = [self refreshState:state forTorrent:torrent] || stateWasBuilt || iinaDirty;

    [self enrichStateWithIinaUnwatched:state forTorrent:torrent];
    torrent.content.cachedPlayButtonProgressGeneration = statsGeneration;
    if (changedOut)
        *changedOut = changed;
    return state;
}

+ (NSArray<NSDictionary*>*)layoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state
{
    if (torrent.content.cachedPlayButtonLayout != nil)
        return torrent.content.cachedPlayButtonLayout;

    if (state.count == 0)
        return nil;

    NSMutableArray<NSDictionary*>* layout = [NSMutableArray array];
    if (state.count == 1)
    {
        [layout addObject:@{ @"kind" : @"item", @"item" : state[0] }];
        torrent.content.cachedPlayButtonLayout = layout;
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

    torrent.content.cachedPlayButtonLayout = layout;
    return layout;
}

@end
