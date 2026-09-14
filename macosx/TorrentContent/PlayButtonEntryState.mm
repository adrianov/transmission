// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Entry-state rules for content play buttons: how one entry is built from a playable file and how
// its progress/visibility/title are refreshed per tick. Pure logic; cache ownership stays in
// PlayButtonStateBuilder.

#include <cmath>

#import "PlayButtonEntryState.h"
#import "PlayButtonTitleHelper.h"
#import "Torrent.h"
#import "VideoDurationHelper.h"

/// Base title for an entry: explicit value when part of a series, verb by category when standalone.
static NSString* playButtonBaseTitle(NSString* category, NSDictionary* entry, BOOL singleItem)
{
    if (!singleItem)
        return entry[@"baseTitle"] ?: @"";
    return [category isEqualToString:@"books"] ? @"Read" : ([category isEqualToString:@"software"] ? @"Open" : @"Play");
}

/// Current progress for an entry: file progress by index, consecutive folder progress for folders.
static CGFloat playButtonProgressForEntry(NSDictionary* entry, Torrent* torrent)
{
    NSNumber* index = entry[@"index"];
    if (index)
        return [torrent fileProgressForIndex:index.unsignedIntegerValue];
    NSString* folder = entry[@"folder"];
    return folder.length > 0 ? [torrent folderConsecutiveProgress:folder] : 0.0;
}

/// Whether the entry's underlying file is wanted (single-index fast path; unchangeable files count as wanted).
static BOOL playButtonEntryIsWanted(NSDictionary* entry, Torrent* torrent)
{
    NSNumber* index = entry[@"index"];
    return index ? [torrent fileIsWantedAtIndex:index.unsignedIntegerValue] : YES;
}

/// Adds progress percentage to display titles of still-downloading visible items.
static void playButtonApplyProgressPercentTitles(NSArray<NSMutableDictionary*>* state)
{
    for (NSMutableDictionary* e in state)
    {
        if (![e[@"visible"] boolValue] || [e[@"type"] hasPrefix:@"document"] || [e[@"progress"] doubleValue] >= 1.0 ||
            [e[@"progressPercent"] intValue] >= 100)
            continue;
        e[@"title"] = [NSString stringWithFormat:@"%@ (%d%%)", e[@"strippedTitle"] ?: @"", [e[@"progressPercent"] intValue]];
    }
}

static NSMutableDictionary* playButtonBuildEntryForFile(NSDictionary* fileInfo, Torrent* torrent, BOOL singleItem)
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

    entry[@"baseTitle"] = playButtonBaseTitle(category, entry, singleItem);
    entry[@"title"] = entry[@"baseTitle"] ?: @"";
    CGFloat progress = playButtonProgressForEntry(entry, torrent);
    entry[@"progress"] = @(progress);
    entry[@"progressPercent"] = @(static_cast<int>(std::floor(progress * 100)));
    entry[@"visible"] = @(playButtonIsItemVisible(type, progress, playButtonEntryIsWanted(entry, torrent)));
    return entry;
}

void playButtonBuildStateForPlayableFiles(NSMutableArray<NSMutableDictionary*>* state, NSArray<NSDictionary*>* playableFiles, Torrent* torrent)
{
    for (NSDictionary* fileInfo in playableFiles)
        [state addObject:playButtonBuildEntryForFile(fileInfo, torrent, playableFiles.count == 1)];
    playButtonApplyTitleStripping(state);
    // For single items playButtonApplyTitleStripping returns early; ensure strippedTitle is set
    if (state.count == 1)
        state[0][@"strippedTitle"] = state[0][@"title"] ?: @"";
    playButtonApplyProgressPercentTitles(state);
}

/// Sets the entry's display title: stripped base, with a percent suffix for visible still-downloading media.
static void playButtonSetEntryTitle(NSMutableDictionary* entry, NSString* type, CGFloat progress, BOOL visible, int progressPct)
{
    NSString* strippedTitle = entry[@"strippedTitle"] ?: entry[@"baseTitle"] ?: @"";
    entry[@"title"] = (visible && ![type hasPrefix:@"document"] && progress < 1.0 && progressPct < 100) ?
        [NSString stringWithFormat:@"%@ (%d%%)", strippedTitle, progressPct] :
        strippedTitle;
}

/// Applies fresh progress to an entry and re-evaluates visibility/title.
static void playButtonApplyProgressToEntry(NSMutableDictionary* entry, Torrent* torrent, CGFloat progress, BOOL wasVisible, BOOL* visibilityChanged)
{
    entry[@"progress"] = @(progress);
    int progressPct = static_cast<int>(std::floor(progress * 100));
    entry[@"progressPercent"] = @(progressPct);
    NSString* type = entry[@"type"] ?: @"file";
    BOOL visible = playButtonIsItemVisible(type, progress, playButtonEntryIsWanted(entry, torrent));
    if (wasVisible && [Torrent isVideoFileExtension:[torrent pathExtensionOfPlayableItem:entry]])
        visible = YES; // Do not re-evaluate ETA < duration once button is shown
    else
        visible = videoDisplayAllowedForItem(torrent, entry, progress, visible);
    entry[@"visible"] = @(visible);
    if (visible != wasVisible)
        *visibilityChanged = YES;
    playButtonSetEntryTitle(entry, type, progress, visible, progressPct);
}

/// ETA depends on download speed; re-evaluate video-file visibility so the button appears when ETA < duration.
static BOOL playButtonRefreshEtaVisibilityForEntry(NSMutableDictionary* entry, Torrent* torrent, CGFloat progress, BOOL wasVisible, BOOL* visibilityChanged)
{
    if (wasVisible || progress >= 1.0 || ![Torrent isVideoFileExtension:[torrent pathExtensionOfPlayableItem:entry]])
        return NO;
    BOOL visible = playButtonIsItemVisible(entry[@"type"] ?: @"file", progress, playButtonEntryIsWanted(entry, torrent));
    visible = videoDisplayAllowedForItem(torrent, entry, progress, visible);
    if (visible == wasVisible)
        return NO;
    *visibilityChanged = YES;
    entry[@"visible"] = @(visible);
    playButtonSetEntryTitle(entry, entry[@"type"] ?: @"file", progress, visible, [entry[@"progressPercent"] intValue]);
    return YES;
}

BOOL playButtonRefreshEntry(NSMutableDictionary* entry, Torrent* torrent, BOOL* visibilityChanged)
{
    CGFloat progress = [entry[@"progress"] doubleValue];
    CGFloat newProgress = playButtonProgressForEntry(entry, torrent);
    if (std::fabs(newProgress - progress) > 0.000001)
    {
        playButtonApplyProgressToEntry(entry, torrent, newProgress, [entry[@"visible"] boolValue], visibilityChanged);
        return YES;
    }
    return playButtonRefreshEtaVisibilityForEntry(entry, torrent, progress, [entry[@"visible"] boolValue], visibilityChanged);
}
