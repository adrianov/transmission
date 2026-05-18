// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "PlayButtonTitleHelper.h"

#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static NSString* preEpisodeTextFromFilename(NSString* filename)
{
    NSString* base = filename.stringByDeletingPathExtension;
    if (base.length == 0)
        return nil;
    static NSRegularExpression* regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"\\bS\\d{1,2}[.\\s]?E\\d{1,3}\\b|\\b\\d{1,2}x\\d{1,3}\\b"
                                                         options:NSRegularExpressionCaseInsensitive
                                                           error:nil];
    });
    NSTextCheckingResult* match = [regex firstMatchInString:base options:0 range:NSMakeRange(0, base.length)];
    if (!match || match.range.location == 0)
        return nil;
    NSString* preText = [[base substringToIndex:match.range.location] stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@". "]];
    if (preText.length == 0)
        return nil;
    NSString* humanized = preText.humanReadableFileName;
    return humanized.length > 0 ? humanized : nil;
}

/// When multiple buttons share the same stripped title within the same season, prepend humanized distinguishing text and re-strip so labels are distinct (e.g. "Career of Evil — S1 E1").
/// Duplicates across different seasons are expected (e.g. "E1" in Season 1 and "E1" in Season 2) and not disambiguated.
static void disambiguateDuplicateTitles(NSMutableArray<NSMutableDictionary*>* state, NSArray<NSNumber*>* seasons)
{
    if (state.count < 2)
        return;
    NSArray<NSString*>* titles = [state valueForKey:@"title"];
    NSCountedSet<NSString*>* counts = [NSCountedSet set];
    for (NSUInteger i = 0; i < state.count; i++)
    {
        NSNumber* season = (seasons && i < seasons.count) ? seasons[i] : @0;
        [counts addObject:[NSString stringWithFormat:@"%@\x01%@", titles[i], season]];
    }
    BOOL anyDuplicate = NO;
    for (NSString* key in counts)
        if ([counts countForObject:key] > 1)
        {
            anyDuplicate = YES;
            break;
        }
    if (!anyDuplicate)
        return;
    for (NSUInteger i = 0; i < state.count; i++)
    {
        NSNumber* season = (seasons && i < seasons.count) ? seasons[i] : @0;
        NSString* key = [NSString stringWithFormat:@"%@\x01%@", titles[i], season];
        if ([counts countForObject:key] < 2)
            continue;
        NSMutableDictionary* e = state[i];
        NSString* path = e[@"path"];
        NSString* prefix = nil;
        if (path.length > 0)
            prefix = preEpisodeTextFromFilename(path.lastPathComponent);
        if (prefix.length == 0)
        {
            NSString* folder = e[@"folder"];
            NSString* parent = (path.length > 0) ? [path stringByDeletingLastPathComponent].lastPathComponent :
                                                   (folder.length > 0 ? (folder.lastPathComponent ?: folder) : @"");
            if (parent.length > 0)
                prefix = parent.humanReadableFileName;
        }
        if (prefix.length == 0)
            continue;
        NSString* base = e[@"baseTitle"] ?: @"";
        e[@"baseTitle"] = [NSString stringWithFormat:@"%@ — %@", prefix, base];
    }
    NSArray<NSString*>* newTitles = [Torrent displayTitlesByStrippingCommonPrefixSuffix:[state valueForKey:@"baseTitle"]
                                                                                seasons:seasons];
    for (NSUInteger i = 0; i < state.count; i++)
    {
        if ([state[i][@"type"] isEqualToString:@"document-books"])
            state[i][@"title"] = state[i][@"baseTitle"] ?: @"";
        else
            state[i][@"title"] = newTitles[i];
    }
}

BOOL playButtonIsItemVisible(NSString* type, CGFloat progress, BOOL wanted)
{
    if ([type isEqualToString:@"album"])
        return YES;
    if ([type hasPrefix:@"document"])
        return progress >= 1.0;
    return wanted && progress >= 0.01;
}

void playButtonApplyTitleStripping(NSMutableArray<NSMutableDictionary*>* state)
{
    if (state.count < 2)
        return;
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
        e[@"strippedTitle"] = e[@"title"] ?: @"";
}
