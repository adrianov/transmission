// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "FileListNode.h"
#import "IINAWatchHelper.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

/// Tokenize into words: split on whitespace; treat balanced (...) as one token so e.g. "1 (stereo).mp3" → ["1", "(stereo)", ".mp3"].
static NSArray<NSString*>* wordTokensFromString(NSString* s);
/// Common suffix length in whole tokens (from end). All arrays must have same count.
static NSUInteger commonSuffixTokenCount(NSArray<NSArray<NSString*>*>* tokenArrays);
/// Common prefix length in whole tokens (from start). All arrays must have same count.
static NSUInteger commonPrefixTokenCount(NSArray<NSArray<NSString*>*>* tokenArrays);
/// Rejoin tokens with single spaces (tokens may be words or "(...)" groups).
static NSString* stringFromWordTokens(NSArray<NSString*>* tokens);
/// Trim trailing whitespace and extra trailing ')' so e.g. "I (2024) " → "I (2024)", "Album (2024))" → "Album (2024)".
static NSString* trimTrailingParenAndSpace(NSString* s);
static NSDictionary<NSString*, NSString*>* commonPrefixAndSuffixForStrings(NSArray<NSString*>* strings);
/// YES if token looks like a season marker (e.g. S1, S01).
static BOOL isSeasonToken(NSString* token);
/// YES if tokens from given index form a disc marker (CD1, Disc 1, CD 2, etc.).
static BOOL isDiscMarkerFromTokenIndex(NSArray<NSString*>* tokens, NSUInteger from);
/// YES if every token array has a disc marker at the common prefix boundary (prefixDrop).
static BOOL allTitlesHaveDiscMarkerAt(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop);
/// YES if the common prefix (0..prefixDrop-1) of the first title contains a season token (S1, S01, etc.).
static BOOL commonPrefixContainsSeasonToken(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop);
/// YES if the common prefix ends with "-" (Artist - Title pattern); allows stripping "Artist - " for album buttons.
static BOOL commonPrefixEndsWithArtistSeparator(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop);
/// YES if every title's remainder (prefixDrop..n-suffixDrop) is a single token matching E + digits (episode-only); do not strip then.
static BOOL allRemaindersAreSingleEpisodeOnlyToken(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop,
                                                   NSUInteger suffixDrop);
/// YES if token is E or e followed only by digits (e.g. E126).
static BOOL isEpisodeOnlyToken(NSString* token);
/// YES if token is digits optionally followed by period (e.g. 01., 02., 1) — leading track number for strip.
static BOOL isLeadingTrackNumberToken(NSString* token);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (Playable)

#pragma mark - Playable item and icon subtitle

/// Path extension of a playable item dict (from @"path" or @"originalExt"). Nil if none.
- (NSString*)pathExtensionOfPlayableItem:(NSDictionary*)item
{
    id pathObj = item[@"path"];
    if ([pathObj isKindOfClass:[NSString class]] && [(NSString*)pathObj length] > 0)
    {
        NSString* ext = [(NSString*)pathObj pathExtension];
        if (ext.length > 0)
            return ext.lowercaseString;
    }
    NSString* ext = item[@"originalExt"];
    return ext.length > 0 ? ext.lowercaseString : nil;
}

/// YES when file-based audio is represented entirely by .cue+companion pairs (one playable entry per pair).
- (BOOL)isFileBasedAudioCueBased
{
    if (self.fMediaType != TorrentMediaTypeAudio)
        return NO;
    NSArray<NSDictionary*>* playable = self.playableFiles;
    if (playable.count == 0)
        return NO;
    for (NSDictionary* item in playable)
    {
        NSString* ext = [self pathExtensionOfPlayableItem:item];
        if ([ext isEqualToString:@"cue"])
            continue;
        if ([self cueFilePathForAudioPath:item[@"path"]] == nil)
            return NO;
    }
    return YES;
}

/// Count to show in file-based icon subtitle. Used by iconSubtitle.
- (NSUInteger)iconSubtitleCountForFileBased
{
    if ([self isFileBasedAudioCueBased])
        return self.playableFiles.count;
    return self.fMediaFileCount;
}

/// Label for file-based icon subtitle. Nil if no label. Used by iconSubtitle.
- (NSString*)iconSubtitleLabelForFileBasedMediaType:(TorrentMediaType)mediaType
{
    switch (mediaType)
    {
    case TorrentMediaTypeVideo:
        return @"videos";
    case TorrentMediaTypeAudio:
        return [self isFileBasedAudioCueBased] ? @"albums" : @"audios";
    case TorrentMediaTypeBooks:
        return @"books";
    case TorrentMediaTypeSoftware:
        return @"software";
    default:
        return nil;
    }
}

- (NSString*)iconSubtitle
{
    if (!self.folder || self.magnet)
        return nil;

    [self detectMediaType];

    if (self.fFolderItems.count > 1)
    {
        if (self.fIsDVD || self.fIsBluRay)
            return [NSString stringWithFormat:@"%lu discs", (unsigned long)self.fFolderItems.count];
        if (self.fIsAlbumCollection)
            return [NSString stringWithFormat:@"%lu albums", (unsigned long)self.fFolderItems.count];
    }

    NSUInteger const count = [self iconSubtitleCountForFileBased];
    NSString* const label = [self iconSubtitleLabelForFileBasedMediaType:self.fMediaType];
    if (count > 1 && label)
        return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, label];
    return nil;
}

#pragma mark - Humanized title for folder playables (content buttons)

/// Humanized display name for a folder-based playable (disc or album). Uses only the folder name; no parent path.
- (NSString*)humanizedTitleForFolderPlayableWithFolder:(NSString*)folder
                                        pathComponents:(NSArray<NSString*>*)parts
                                                isDisc:(BOOL)isDisc
                                                 index:(NSUInteger)index
{
    NSString* name = folder.lastPathComponent;

    if (isDisc && parts.count >= 2)
    {
        NSString* upperName = name.uppercaseString;
        if ([upperName isEqualToString:@"VIDEO_TS"] || [upperName isEqualToString:@"BDMV"])
        {
            name = parts[parts.count - 2];
        }
    }

    if (isDisc && name.length > 0)
    {
        name = name.humanReadableFileName;
    }

    if (name.length == 0)
    {
        name = [NSString stringWithFormat:@"%@ %lu", (isDisc ? @"Disc" : @"Album"), (unsigned long)(index + 1)];
    }
    else if (!isDisc)
    {
        name = name.humanReadableFileName;
    }
    return name;
}

#pragma mark - Playable files list

- (NSArray<NSDictionary*>*)playableFiles
{
    [self detectMediaType];

    if (self.fPlayableFiles.count > 0)
    {
        BOOL needsFolderBased = (self.fIsDVD || self.fIsBluRay || self.fIsAlbumCollection);
        NSString* cachedType = self.fPlayableFiles.firstObject[@"type"];
        BOOL isFolderType = [cachedType isEqualToString:@"dvd"] || [cachedType isEqualToString:@"bluray"] ||
            [cachedType isEqualToString:@"album"];

        if (needsFolderBased != isFolderType)
        {
            self.fPlayableFiles = nil;
        }
        else
        {
            return self.fPlayableFiles;
        }
    }

    if (self.magnet || self.fileCount == 0)
    {
        return nil;
    }

    if (self.fFolderItems.count > 0)
    {
        NSMutableArray<NSDictionary*>* entries = [NSMutableArray arrayWithCapacity:self.fFolderItems.count];
        NSArray<NSString*>* folders = [self.fFolderItems sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

        NSString* type = self.fIsDVD ? @"dvd" : (self.fIsBluRay ? @"bluray" : @"album");
        BOOL isDisc = self.fIsDVD || self.fIsBluRay;

        for (NSUInteger i = 0; i < folders.count; i++)
        {
            NSString* folder = folders[i];
            NSString* fullPath = [self.currentDirectory stringByAppendingPathComponent:folder];

            CGFloat progress = [self folderConsecutiveProgress:folder];

            // For discs, hide folder button when nothing wanted and not complete. For albums, always show so all albums get a button.
            if (isDisc)
            {
                NSArray<NSNumber*>* fileIndices = self.fFolderToFiles[folder];
                BOOL anyFileWanted = NO;
                if (fileIndices)
                {
                    for (NSNumber* fileIndex in fileIndices)
                    {
                        auto const file = tr_torrentFile(self.fHandle, (tr_file_index_t)fileIndex.unsignedIntegerValue);
                        if (file.wanted)
                        {
                            anyFileWanted = YES;
                            break;
                        }
                    }
                }
                if (!anyFileWanted && progress < 1.0)
                    continue;
            }

            NSString* name;
            if (folders.count == 1 && isDisc)
            {
                name = self.fIsDVD ? @"DVD" : @"Blu-ray";
            }
            else
            {
                NSArray<NSString*>* parts = [folder pathComponents];
                name = [self humanizedTitleForFolderPlayableWithFolder:folder pathComponents:parts isDisc:isDisc index:i];
            }

            [entries addObject:@{
                @"type" : type,
                @"name" : name,
                @"path" : fullPath,
                @"folder" : folder,
                @"progress" : @(progress),
                @"baseTitle" : name
            }];
        }

        self.fPlayableFiles = entries;
        return self.fPlayableFiles;
    }

    self.fPlayableFiles = [self buildIndividualFilePlayables];
    return self.fPlayableFiles;
}

- (NSDictionary*)preferredPlayableItemFromList:(NSArray<NSDictionary*>*)playableFiles
{
    if (playableFiles.count == 0)
        return nil;
    for (NSDictionary* item in playableFiles)
    {
        NSString* path = item[@"path"];
        if ([path.pathExtension.lowercaseString isEqualToString:@"cue"])
            return item;
    }
    for (NSDictionary* item in playableFiles)
    {
        if ([item[@"progress"] doubleValue] > 0)
            return item;
    }
    return playableFiles.firstObject;
}

#pragma mark - Individual file playables

/// Returns stripped display titles for a group (2+ items). Single title returned as-is. Used by buttons and context menu.
/// When all titles start with a track-number token (e.g. 01., 02.), that token is kept and common prefix/suffix is
/// computed on the remainder so e.g. "01. Artist - Song (Digitally Restored)" → "01. Song". Word-boundary stripping:
/// tokenize (whitespace-split; balanced "(...)" as one token), remove common leading and trailing tokens, rejoin.
/// Season token (e.g. S1) is stripped only when 2+ titles share that season. Keeps "(stereo)" intact.
+ (NSArray<NSString*>*)displayTitlesByStrippingCommonPrefixSuffix:(NSArray<NSString*>*)titles
{
    return [self displayTitlesByStrippingCommonPrefixSuffix:titles seasons:nil];
}

+ (NSArray<NSString*>*)displayTitlesByStrippingCommonPrefixSuffix:(NSArray<NSString*>*)titles
                                                         seasons:(NSArray<NSNumber*>*)seasons
{
    if (titles.count < 2)
        return titles;
    NSMutableArray<NSArray<NSString*>*>* tokenArrays = [NSMutableArray arrayWithCapacity:titles.count];
    NSCharacterSet* ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (id raw in titles)
    {
        NSString* s = [raw isKindOfClass:[NSString class]] ? raw : nil;
        if (s.length > 0)
            s = [s stringByTrimmingCharactersInSet:ws];
        NSArray<NSString*>* tokens = (s.length > 0) ? wordTokensFromString(s) : @[];
        [tokenArrays addObject:tokens];
    }
    NSMutableArray<NSString*>* leadingTokens = nil;
    NSMutableArray<NSArray<NSString*>*>* workArrays = [NSMutableArray arrayWithArray:tokenArrays];
    BOOL allHaveLeadingTrackNum = YES;
    for (NSArray<NSString*>* arr in tokenArrays)
    {
        if (arr.count == 0 || !isLeadingTrackNumberToken(arr[0]))
        {
            allHaveLeadingTrackNum = NO;
            break;
        }
    }
    if (allHaveLeadingTrackNum)
    {
        leadingTokens = [NSMutableArray arrayWithCapacity:titles.count];
        workArrays = [NSMutableArray arrayWithCapacity:titles.count];
        for (NSArray<NSString*>* arr in tokenArrays)
        {
            [leadingTokens addObject:arr[0]];
            [workArrays addObject:[arr subarrayWithRange:NSMakeRange(1, arr.count - 1)]];
        }
    }
    NSUInteger suffixDrop = commonSuffixTokenCount(workArrays);
    NSUInteger prefixDrop = commonPrefixTokenCount(workArrays);
    // Allow prefix strip when: season token (S1, S01), or remainder is disc marker (CD1, Disc 1), or "Artist - " pattern.
    if (prefixDrop > 0 && !commonPrefixContainsSeasonToken(workArrays, prefixDrop) &&
        !allTitlesHaveDiscMarkerAt(workArrays, prefixDrop) &&
        !commonPrefixEndsWithArtistSeparator(workArrays, prefixDrop))
        prefixDrop = 0;
    // Do not strip when the remainder would be only an episode-only token (e.g. E126); keep full title.
    if (prefixDrop > 0 && allRemaindersAreSingleEpisodeOnlyToken(workArrays, prefixDrop, suffixDrop) &&
        !commonPrefixContainsSeasonToken(workArrays, prefixDrop))
        prefixDrop = 0;
    BOOL stripSeasonOnlyWhenMultiple = (seasons != nil && seasons.count == titles.count && prefixDrop > 0);
    NSMutableArray<NSNumber*>* effectivePrefixDrop = nil;
    if (stripSeasonOnlyWhenMultiple)
    {
        effectivePrefixDrop = [NSMutableArray arrayWithCapacity:titles.count];
        for (NSUInteger i = 0; i < titles.count; i++)
        {
            NSInteger seasonVal = [seasons[i] integerValue];
            NSUInteger count = 0;
            for (NSUInteger j = 0; j < titles.count; j++)
                if ([seasons[j] integerValue] == seasonVal)
                    count++;
            NSUInteger drop = (count >= 2) ? prefixDrop : (prefixDrop > 0 ? prefixDrop - 1 : 0);
            [effectivePrefixDrop addObject:@(drop)];
        }
    }
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSUInteger i = 0; i < titles.count; i++)
    {
        NSString* raw = titles[i];
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0)
        {
            [result addObject:raw ?: @""];
            continue;
        }
        NSArray<NSString*>* tokens = workArrays[i];
        NSUInteger n = tokens.count;
        NSUInteger from = effectivePrefixDrop ? [effectivePrefixDrop[i] unsignedIntegerValue] : prefixDrop;
        NSUInteger to = (n > suffixDrop) ? n - suffixDrop : from;
        NSString* joined;
        if (from >= to)
            joined = nil;
        else
        {
            NSArray<NSString*>* kept = [tokens subarrayWithRange:NSMakeRange(from, to - from)];
            joined = trimTrailingParenAndSpace(stringFromWordTokens(kept));
        }
        if (joined.length == 0)
            [result addObject:raw];
        else if (leadingTokens)
            [result addObject:[[leadingTokens[i] stringByAppendingString:@" "] stringByAppendingString:joined]];
        else
            [result addObject:joined];
    }
    return result;
}

static BOOL isSeasonToken(NSString* token)
{
    if (token.length < 2)
        return NO;
    unichar c = [token characterAtIndex:0];
    if (c != 'S' && c != 's')
        return NO;
    for (NSUInteger i = 1; i < token.length; i++)
        if (![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[token characterAtIndex:i]])
            return NO;
    return YES;
}

static BOOL isDiscMarkerFromTokenIndex(NSArray<NSString*>* tokens, NSUInteger from)
{
    if (from >= tokens.count)
        return NO;
    NSString* t0 = [tokens[from] lowercaseString];
    if (t0.length == 0)
        return NO;
    NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
    if (from >= 1)
    {
        NSString* prev = [tokens[from - 1] lowercaseString];
        if (([prev isEqualToString:@"disc"] || [prev isEqualToString:@"disk"] || [prev isEqualToString:@"cd"]) &&
            [t0 stringByTrimmingCharactersInSet:digits].length == 0)
            return YES; // "Disc 1", "Disk 1", "CD 1" etc. with marker word in common prefix
    }
    if ([t0 isEqualToString:@"cd"] || [t0 isEqualToString:@"disc"] || [t0 isEqualToString:@"disk"])
    {
        if (from + 1 < tokens.count)
        {
            NSString* t1 = tokens[from + 1];
            if (t1.length > 0 && [t1 stringByTrimmingCharactersInSet:digits].length == 0)
                return YES;
        }
        return NO;
    }
    if (t0.length >= 3 && [t0 hasPrefix:@"cd"])
    {
        NSString* rest = [t0 substringFromIndex:2];
        return rest.length > 0 && [rest stringByTrimmingCharactersInSet:digits].length == 0;
    }
    if (t0.length >= 4 && [t0 hasPrefix:@"disc"])
    {
        NSString* rest = [t0 substringFromIndex:4];
        return rest.length > 0 && [rest stringByTrimmingCharactersInSet:digits].length == 0;
    }
    if (t0.length >= 5 && [t0 hasPrefix:@"disk"])
    {
        NSString* rest = [t0 substringFromIndex:4];
        return rest.length > 0 && [rest stringByTrimmingCharactersInSet:digits].length == 0;
    }
    return NO;
}

static BOOL allTitlesHaveDiscMarkerAt(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop)
{
    for (NSArray<NSString*>* tokens in tokenArrays)
    {
        if (!isDiscMarkerFromTokenIndex(tokens, prefixDrop))
            return NO;
    }
    return YES;
}

static BOOL commonPrefixContainsSeasonToken(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop)
{
    if (prefixDrop == 0 || tokenArrays.count == 0)
        return NO;
    NSArray<NSString*>* first = tokenArrays[0];
    for (NSUInteger k = 0; k < prefixDrop && k < first.count; k++)
    {
        if (isSeasonToken(first[k]))
            return YES;
    }
    return NO;
}

static BOOL commonPrefixEndsWithArtistSeparator(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop)
{
    if (prefixDrop == 0 || tokenArrays.count == 0)
        return NO;
    return [tokenArrays[0][prefixDrop - 1] isEqualToString:@"-"];
}

static BOOL isEpisodeOnlyToken(NSString* token)
{
    if (token.length < 2)
        return NO;
    unichar c = [token characterAtIndex:0];
    if (c != 'E' && c != 'e')
        return NO;
    for (NSUInteger i = 1; i < token.length; i++)
        if (![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[token characterAtIndex:i]])
            return NO;
    return YES;
}

static BOOL allRemaindersAreSingleEpisodeOnlyToken(NSArray<NSArray<NSString*>*>* tokenArrays, NSUInteger prefixDrop,
                                                  NSUInteger suffixDrop)
{
    for (NSArray<NSString*>* tokens in tokenArrays)
    {
        NSUInteger n = tokens.count;
        NSUInteger to = (n > suffixDrop) ? n - suffixDrop : prefixDrop;
        if (to <= prefixDrop || to - prefixDrop != 1)
            return NO;
        if (!isEpisodeOnlyToken(tokens[prefixDrop]))
            return NO;
    }
    return YES;
}

static BOOL isLeadingTrackNumberToken(NSString* token)
{
    if (token.length == 0)
        return NO;
    NSUInteger i = 0;
    NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
    while (i < token.length && [digits characterIsMember:[token characterAtIndex:i]])
        i++;
    if (i == 0)
        return NO;
    if (i < token.length && [token characterAtIndex:i] == '.')
        i++;
    return i == token.length;
}

static NSArray<NSString*>* wordTokensFromString(NSString* s)
{
    NSUInteger len = s.length;
    if (len == 0)
        return @[];

    NSMutableArray<NSString*>* tokens = [NSMutableArray arrayWithCapacity:(len / 3) + 1];
    unichar* buf = (unichar*)malloc(len * sizeof(unichar));
    [s getCharacters:buf range:NSMakeRange(0, len)];
    NSCharacterSet* ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSUInteger i = 0;
    while (i < len)
    {
        unichar c = buf[i];
        if ([ws characterIsMember:c])
        {
            i++;
            continue;
        }
        if (c == '(')
        {
            NSUInteger start = i;
            NSUInteger depth = 1;
            i++;
            while (i < len && depth > 0)
            {
                if (buf[i] == '(')
                    depth++;
                else if (buf[i] == ')')
                    depth--;
                i++;
            }
            [tokens addObject:[s substringWithRange:NSMakeRange(start, i - start)]];
            continue;
        }
        NSUInteger start = i;
        while (i < len && ![ws characterIsMember:buf[i]] && buf[i] != '(')
            i++;
        if (i > start)
            [tokens addObject:[s substringWithRange:NSMakeRange(start, i - start)]];
    }
    free(buf);
    return [tokens copy];
}

static NSUInteger commonSuffixTokenCount(NSArray<NSArray<NSString*>*>* tokenArrays)
{
    if (tokenArrays.count < 2)
        return 0;
    NSUInteger minLen = NSUIntegerMax;
    for (NSArray<NSString*>* arr in tokenArrays)
    {
        NSUInteger n = arr.count;
        if (n < minLen)
            minLen = n;
    }
    for (NSUInteger k = 0; k < minLen; k++)
    {
        NSString* last0 = tokenArrays[0][tokenArrays[0].count - 1 - k];
        for (NSUInteger i = 1; i < tokenArrays.count; i++)
        {
            NSArray<NSString*>* arr = tokenArrays[i];
            if (![arr[arr.count - 1 - k] isEqualToString:last0])
                return k;
        }
    }
    return minLen;
}

static NSUInteger commonPrefixTokenCount(NSArray<NSArray<NSString*>*>* tokenArrays)
{
    if (tokenArrays.count < 2)
        return 0;
    NSUInteger minLen = NSUIntegerMax;
    for (NSArray<NSString*>* arr in tokenArrays)
    {
        if (arr.count < minLen)
            minLen = arr.count;
    }
    for (NSUInteger k = 0; k < minLen; k++)
    {
        NSString* first0 = tokenArrays[0][k];
        for (NSUInteger i = 1; i < tokenArrays.count; i++)
        {
            if (![tokenArrays[i][k] isEqualToString:first0])
                return k;
        }
    }
    return minLen;
}

static NSString* stringFromWordTokens(NSArray<NSString*>* tokens)
{
    return [tokens count] == 0 ? @"" : [tokens componentsJoinedByString:@" "];
}

static NSString* trimTrailingParenAndSpace(NSString* s)
{
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while (s.length > 0 && [s characterAtIndex:s.length - 1] == ')')
    {
        NSUInteger open = 0, close = 0;
        for (NSUInteger j = 0; j < s.length; j++)
        {
            unichar c = [s characterAtIndex:j];
            if (c == '(')
                open++;
            else if (c == ')')
                close++;
        }
        if (close <= open)
            break;
        s = [s substringToIndex:s.length - 1];
    }
    return s;
}

/// Returns common prefix and suffix for an array of strings (e.g. sibling file paths or folder names).
static NSDictionary<NSString*, NSString*>* commonPrefixAndSuffixForStrings(NSArray<NSString*>* strings)
{
    static NSCharacterSet* separators;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        separators = [NSCharacterSet characterSetWithCharactersInString:@".-_ "];
    });
    NSString* prefix = @"";
    NSString* suffix = @"";
    if (strings.count < 2)
        return @{ @"prefix" : prefix, @"suffix" : suffix };
    for (NSString* s in strings)
    {
        if (prefix.length == 0)
            prefix = s;
        else
        {
            NSUInteger j = 0;
            while (j < prefix.length && j < s.length && [prefix characterAtIndex:j] == [s characterAtIndex:j])
                j++;
            prefix = [prefix substringToIndex:j];
        }
        if (suffix.length == 0)
            suffix = s;
        else
        {
            NSUInteger j = 0;
            while (j < suffix.length && j < s.length &&
                   [suffix characterAtIndex:suffix.length - 1 - j] == [s characterAtIndex:s.length - 1 - j])
                j++;
            suffix = [suffix substringFromIndex:suffix.length - j];
        }
    }
    if (prefix.length > 0)
    {
        NSUInteger lastSep = [prefix rangeOfCharacterFromSet:separators options:NSBackwardsSearch].location;
        prefix = (lastSep != NSNotFound) ? [prefix substringToIndex:lastSep + 1] : @"";
    }
    if (suffix.length > 0)
    {
        NSUInteger firstSep = [suffix rangeOfCharacterFromSet:separators].location;
        suffix = (firstSep != NSNotFound) ? [suffix substringFromIndex:firstSep] : @"";
    }
    return @{ @"prefix" : prefix ?: @"", @"suffix" : suffix ?: @"" };
}

- (NSArray<NSDictionary*>*)buildIndividualFilePlayables
{
    static NSRegularExpression* nonWordRegex;
    static NSArray<NSString*>* codecTokens;
    static NSArray<NSRegularExpression*>* codecRegexes;
    static dispatch_once_t codecOnceToken;
    dispatch_once(&codecOnceToken, ^{
        nonWordRegex = [NSRegularExpression regularExpressionWithPattern:@"[^\\p{L}\\p{N}]" options:0 error:nil];
        codecTokens = @[ @"flac", @"wav", @"mp3", @"ape", @"alac", @"aiff", @"wma", @"m4a", @"ogg", @"opus" ];
        NSMutableArray<NSRegularExpression*>* regexes = [NSMutableArray arrayWithCapacity:codecTokens.count];
        for (NSString* token in codecTokens)
        {
            NSString* pattern = [NSString stringWithFormat:@"(^|[^\\p{L}\\p{N}])%@(\\b|[^\\p{L}\\p{N}])", token];
            NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            [regexes addObject:regex];
        }
        codecRegexes = [regexes copy];
    });

    NSMutableDictionary<NSString*, NSString*>* normalizedCache = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* codecCache = [NSMutableDictionary dictionary];

    NSString* (^normalizedMediaKeyWithoutCodec)(NSString*) = ^NSString*(NSString* value) {
        if (value.length == 0)
            return @"";
        NSString* cacheKey = [@"__nocodec__" stringByAppendingString:value];
        NSString* cached = normalizedCache[cacheKey];
        if (cached)
            return cached;
        NSString* lowercase = value.lowercaseString;
        for (NSRegularExpression* regex in codecRegexes)
        {
            lowercase = [regex stringByReplacingMatchesInString:lowercase options:0 range:NSMakeRange(0, lowercase.length)
                                                   withTemplate:@""];
        }
        NSString* normalized = [nonWordRegex stringByReplacingMatchesInString:lowercase options:0
                                                                        range:NSMakeRange(0, lowercase.length)
                                                                 withTemplate:@""];
        normalizedCache[cacheKey] = normalized;
        return normalized;
    };
    NSString* (^extractCodecToken)(NSString*) = ^NSString*(NSString* value) {
        if (value.length == 0)
            return @"";
        NSString* cached = codecCache[value];
        if (cached)
            return cached;
        NSString* lowercase = value.lowercaseString;
        NSUInteger index = 0;
        for (NSRegularExpression* regex in codecRegexes)
        {
            if ([regex firstMatchInString:lowercase options:0 range:NSMakeRange(0, lowercase.length)] != nil)
            {
                NSString* token = codecTokens[index];
                codecCache[value] = token;
                return token;
            }
            index++;
        }
        codecCache[value] = @"";
        return @"";
    };

    static NSSet<NSString*>* mediaExtensions;
    static NSSet<NSString*>* documentExtensions;
    static NSSet<NSString*>* documentExternalExtensions;
    static NSSet<NSString*>* cueCompanionExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediaExtensions = [NSSet setWithArray:@[
            @"mkv",  @"avi",  @"mp4", @"mov", @"wmv",  @"flv",  @"webm", @"m4v",  @"mpg", @"mpeg", @"ts",  @"m2ts",
            @"vob",  @"3gp",  @"ogv", @"mp3", @"flac", @"wav",  @"aac",  @"ogg",  @"wma", @"m4a",  @"ape", @"alac",
            @"aiff", @"opus", @"wv",  @"cue", @"pdf",  @"epub", @"fb2",  @"mobi", @"djv", @"djvu"
        ]];
        documentExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
        documentExternalExtensions = [NSSet setWithArray:@[ @"djv", @"djvu", @"fb2", @"mobi" ]];
        cueCompanionExtensions = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv" ]];
    });

    NSMutableArray<NSDictionary*>* playable = [NSMutableArray array];
    NSUInteger const count = self.fileCount;

    NSMutableSet<NSString*>* cueBaseNames = [NSMutableSet set];
    NSMutableDictionary<NSString*, NSNumber*>* cueFileIndexes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* cueFileNames = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* cueBaseNormalized = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* cueBaseCodec = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* cueByNormalized = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*>* cueAudioIndexes = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        if ([fileName.pathExtension.lowercaseString isEqualToString:@"cue"])
        {
            NSString* baseName = fileName.stringByDeletingPathExtension;
            [cueBaseNames addObject:baseName];
            cueFileIndexes[baseName] = @(i);
            cueFileNames[baseName] = fileName;
            NSString* normalized = normalizedMediaKeyWithoutCodec(baseName);
            if (normalized.length > 0)
            {
                cueBaseNormalized[baseName] = normalized;
                NSString* token = extractCodecToken(baseName);
                if (token.length > 0)
                {
                    cueBaseCodec[baseName] = token;
                }
                NSMutableArray<NSString*>* entries = cueByNormalized[normalized];
                if (!entries)
                {
                    entries = [NSMutableArray array];
                    cueByNormalized[normalized] = entries;
                }
                [entries addObject:baseName];
            }
        }
    }

    NSMutableSet<NSString*>* pdfBaseNames = [NSMutableSet set];
    NSMutableSet<NSString*>* epubBaseNames = [NSMutableSet set];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        NSString* ext = fileName.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"pdf"])
        {
            [pdfBaseNames addObject:fileName.stringByDeletingPathExtension.lowercaseString];
        }
        else if ([ext isEqualToString:@"epub"])
        {
            [epubBaseNames addObject:fileName.stringByDeletingPathExtension.lowercaseString];
        }
    }

    NSMutableDictionary<NSString*, NSNumber*>* cueProgress = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* siblingFilesByParent = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* path = [NSString convertedStringFromCString:file.name];
        NSString* parent = path.stringByDeletingLastPathComponent;
        NSMutableArray<NSString*>* siblings = siblingFilesByParent[parent];
        if (!siblings)
        {
            siblings = [NSMutableArray array];
            siblingFilesByParent[parent] = siblings;
        }
        [siblings addObject:path];
    }

    NSMutableDictionary<NSString*, NSString*>* commonPrefixByParent = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* commonSuffixByParent = [NSMutableDictionary dictionary];
    for (NSString* parent in siblingFilesByParent)
    {
        NSArray<NSString*>* paths = siblingFilesByParent[parent];
        NSDictionary* pair = commonPrefixAndSuffixForStrings(paths);
        commonPrefixByParent[parent] = pair[@"prefix"] ?: @"";
        commonSuffixByParent[parent] = pair[@"suffix"] ?: @"";
    }

    for (NSUInteger i = 0; i < count; i++)
    {
        auto const file = tr_torrentFile(self.fHandle, i);
        NSString* fileName = [NSString convertedStringFromCString:file.name];
        NSString* originalFileName = fileName;
        NSString* parent = fileName.stringByDeletingLastPathComponent;
        NSString* commonPrefix = commonPrefixByParent[parent] ?: @"";
        NSString* commonSuffix = commonSuffixByParent[parent] ?: @"";

        if (commonPrefix.length > 0 && [fileName hasPrefix:commonPrefix] && fileName.length > commonPrefix.length)
            fileName = [fileName substringFromIndex:commonPrefix.length];
        if (commonSuffix.length > 0 && [fileName hasSuffix:commonSuffix] && fileName.length > commonSuffix.length)
            fileName = [fileName substringToIndex:fileName.length - commonSuffix.length];

        NSString* ext = originalFileName.pathExtension.lowercaseString;

        if (![mediaExtensions containsObject:ext])
            continue;

        if ([ext isEqualToString:@"cue"])
            continue;

        if ([ext isEqualToString:@"vob"] && [fileName.uppercaseString containsString:@"VIDEO_TS/"])
            continue;
        if ([ext isEqualToString:@"m2ts"] && [fileName.uppercaseString containsString:@"BDMV/"])
            continue;

        if ([cueCompanionExtensions containsObject:ext])
        {
            NSString* audioBaseName = fileName.stringByDeletingPathExtension;
            NSString* normalized = normalizedMediaKeyWithoutCodec(audioBaseName);
            NSArray<NSString*>* candidateCues = normalized.length > 0 ? cueByNormalized[normalized] : nil;
            NSString* matchedCue = nil;
            for (NSString* cueBaseName in candidateCues)
            {
                NSString* cueCodec = cueBaseCodec[cueBaseName] ?: @"";
                if (cueCodec.length > 0 && ![cueCodec isEqualToString:ext])
                    continue;
                matchedCue = cueBaseName;
                break;
            }
            if (matchedCue)
            {
                CGFloat audioProgress = tr_torrentFileConsecutiveProgress(self.fHandle, i);
                if (audioProgress < 0)
                    audioProgress = 0;
                cueProgress[matchedCue] = @(audioProgress);
                cueAudioIndexes[matchedCue] = @(i);
                continue;
            }
        }

        BOOL const isDjvu = [ext isEqualToString:@"djvu"] || [ext isEqualToString:@"djv"];
        BOOL const isFb2 = [ext isEqualToString:@"fb2"];

        if (isDjvu)
        {
            NSString* baseName = originalFileName.stringByDeletingPathExtension.lowercaseString;
            if ([pdfBaseNames containsObject:baseName])
                continue;
        }
        if (isFb2)
        {
            NSString* baseName = originalFileName.stringByDeletingPathExtension.lowercaseString;
            if ([epubBaseNames containsObject:baseName])
                continue;
        }

        CGFloat progress = tr_torrentFileConsecutiveProgress(self.fHandle, i);
        if (progress < 0)
            progress = 0;

        if (!file.wanted && progress < 1.0)
            continue;

        NSString* path = [self.currentDirectory stringByAppendingPathComponent:originalFileName];

        BOOL const isDocument = [documentExtensions containsObject:ext];
        BOOL useCompanionPdf = NO;
        BOOL useCompanionEpub = NO;
        NSString* companionPdfPath = nil;
        NSString* companionEpubPath = nil;

        if (isDjvu)
        {
            companionPdfPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"pdf"];
            if ([NSFileManager.defaultManager fileExistsAtPath:companionPdfPath])
            {
                useCompanionPdf = YES;
                path = companionPdfPath;
            }
        }

        if (isFb2)
        {
            companionEpubPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"epub"];
            if ([NSFileManager.defaultManager fileExistsAtPath:companionEpubPath])
            {
                useCompanionEpub = YES;
                path = companionEpubPath;
            }
        }

        if (isDocument && [documentExternalExtensions containsObject:ext] && !useCompanionPdf && !useCompanionEpub && !isDjvu && !isFb2)
        {
            NSURL* checkURL = [NSURL fileURLWithPath:[self.currentDirectory stringByAppendingPathComponent:fileName]];
            NSURL* appURL = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:checkURL];
            if (!appURL)
                continue;
        }
        NSString* category = [self mediaCategoryForFile:i];
        NSArray<NSNumber*>* episodeNumbers = (isDocument || [category isEqualToString:@"audio"]) ? nil : fileName.episodeNumbers;
        NSNumber* season = episodeNumbers ? episodeNumbers[0] : @0;
        NSNumber* episode = episodeNumbers ? episodeNumbers[1] : @(i);

        NSString* displayName = nil;
        if (isDocument || [category isEqualToString:@"audio"])
        {
            displayName = fileName.lastPathComponent.stringByDeletingPathExtension.humanReadableFileName;
        }
        else
        {
            displayName = [fileName.lastPathComponent humanReadableEpisodeTitleWithTorrentName:self.name];
            if (!displayName)
                displayName = fileName.lastPathComponent.humanReadableEpisodeName;
            if (!displayName)
                displayName = fileName.lastPathComponent.stringByDeletingPathExtension.humanReadableFileName;
        }

        BOOL const opensInBooks = (isDocument && ![documentExternalExtensions containsObject:ext]) || useCompanionPdf || useCompanionEpub;
        [playable addObject:@{
            @"type" : isDocument ? (opensInBooks ? @"document-books" : @"document") : @"file",
            @"category" : category ?: @"",
            @"index" : @(i),
            @"name" : displayName,
            @"path" : path,
            @"season" : season,
            @"episode" : episode,
            @"progress" : @(progress),
            @"sortKey" : fileName.lastPathComponent,
            @"originalExt" : ext,
            @"isCompanion" : @(useCompanionPdf || useCompanionEpub)
        }];
    }

    for (NSString* cueBaseName in cueBaseNames)
    {
        NSNumber* cueIndex = cueFileIndexes[cueBaseName];
        NSNumber* audioIndex = cueAudioIndexes[cueBaseName];
        if (cueIndex && audioIndex)
        {
            NSString* cueFileName = cueFileNames[cueBaseName];
            CGFloat progress = cueProgress[cueBaseName] ? cueProgress[cueBaseName].doubleValue : 0.0;
            if (progress < 0)
                progress = 0;

            NSString* path = [self.currentDirectory stringByAppendingPathComponent:cueFileName];
            NSString* displayName = cueBaseName.humanReadableFileName;

            [playable addObject:@{
                @"type" : @"album",
                @"category" : @"audio",
                @"index" : cueIndex,
                @"name" : displayName,
                @"path" : path,
                @"season" : @0,
                @"episode" : cueIndex,
                @"progress" : @(progress),
                @"sortKey" : cueFileName,
                @"originalExt" : @"cue",
                @"isCompanion" : @NO
            }];
        }
    }

    if (playable.count == 0)
        return nil;

    [playable sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        NSString* aKey = a[@"sortKey"] ?: a[@"name"];
        NSString* bKey = b[@"sortKey"] ?: b[@"name"];
        return [aKey localizedStandardCompare:bKey];
    }];

    NSMutableArray<NSDictionary*>* result = [NSMutableArray arrayWithCapacity:playable.count];
    for (NSDictionary* fileInfo in playable)
    {
        NSString* path = fileInfo[@"path"];
        NSString* pathExt = path.pathExtension.lowercaseString;
        if ([pathExt isEqualToString:@"djvu"] || [pathExt isEqualToString:@"djv"] || [pathExt isEqualToString:@"fb2"])
            continue;

        NSMutableDictionary* entry = [fileInfo mutableCopy];
        entry[@"baseTitle"] = fileInfo[@"name"];
        [result addObject:entry];
    }

    return result;
}

#pragma mark - Display name for playable item (button title source)

/// Path to use when deriving UI display name for a playable item (menu, tooltip). Prefers .cue when present for audio.
- (NSString*)pathForDisplayNameForPlayableItem:(NSDictionary*)item
{
    NSString* type = item[@"type"] ?: @"file";
    if ([type isEqualToString:@"track"])
    {
        NSString* folder = item[@"folder"];
        if (folder.length > 0)
        {
            NSString* pathToOpen = [self pathToOpenForFolder:folder];
            if (pathToOpen.length > 0 && [pathToOpen.pathExtension.lowercaseString isEqualToString:@"cue"])
                return pathToOpen;
            NSString* trackPath = item[@"path"];
            if (trackPath.length > 0)
                return trackPath;
        }
    }
    NSString* pathToOpen = [self pathToOpenForPlayableItem:item];
    if (pathToOpen.length > 0)
    {
        static NSSet<NSString*>* audioExts;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            audioExts = [NSSet setWithArray:@[ @"flac", @"ape", @"wav", @"wma", @"alac", @"aiff", @"wv" ]];
        });
        NSString* ext = pathToOpen.pathExtension.lowercaseString;
        if ([audioExts containsObject:ext])
        {
            NSString* cuePath = [self cueFilePathForAudioPath:pathToOpen];
            if (cuePath.length > 0)
                return cuePath;
        }
        return pathToOpen;
    }
    NSString* itemPath = item[@"path"];
    if (itemPath.length > 0)
    {
        NSString* cuePath = [self cueFilePathForAudioPath:itemPath];
        if (cuePath.length > 0)
            return cuePath;
    }
    return @"";
}

/// YES if path has .cue extension (display name then means album; otherwise it may be the track file and would duplicate the track title).
- (BOOL)pathIsCueFile:(NSString*)path
{
    return path.length > 0 && [path.pathExtension.lowercaseString isEqualToString:@"cue"];
}

/// Display name for a track submenu item. pathForName is the path used to derive nameFromPath (e.g. .cue or audio file).
- (NSString*)displayNameForTrackItem:(NSDictionary*)item pathForName:(NSString*)pathForName nameFromPath:(NSString*)nameFromPath
{
    if (![self pathIsCueFile:pathForName])
        return nameFromPath;
    NSString* trackName = item[@"name"];
    if (trackName.length > 0)
        return [NSString stringWithFormat:@"%@ – %@", nameFromPath, trackName];
    return nameFromPath;
}

- (NSString*)displayNameForPlayableItem:(NSDictionary*)item
{
    NSString* pathForName = [self pathForDisplayNameForPlayableItem:item];
    if (pathForName.length > 0)
    {
        NSString* base = pathForName.lastPathComponent.stringByDeletingPathExtension;
        if (base.length > 0)
        {
            NSString* name = base.humanReadableFileName;
            if ([item[@"type"] isEqualToString:@"track"])
                return [self displayNameForTrackItem:item pathForName:pathForName nameFromPath:name];
            return name;
        }
    }
    NSString* fallback = item[@"baseTitle"] ?: item[@"name"];
    return fallback.length > 0 ? fallback : @"";
}

@end
#pragma clang diagnostic pop
