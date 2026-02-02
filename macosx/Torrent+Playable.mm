// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "FileListNode.h"
#import "IINAWatchHelper.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static NSDictionary<NSString*, NSString*>* commonPrefixAndSuffixForStrings(NSArray<NSString*>* strings);

static NSCharacterSet* titleTrimCharacterSet(void)
{
    static NSCharacterSet* set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet* combined = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
        [combined addCharactersInString:@".-_"];
        set = [combined copy];
    });
    return set;
}

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

/// Minimum path components required to add parent dir to CD/Disc button title.
/// E.g. 2 = add parent for "Album/CD1" (-> "Album - CD1"); 3 = add only for "Artist/Album/CD1", not for top-level "TorrentName/CD1".
static NSUInteger const kMinPathComponentsForCDParentInTitle = 2;

/// Humanized display name for a folder-based playable (disc or album). Single place for CD/Disc parent rule.
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
    else
    {
        BOOL addParentToCD = (parts.count >= kMinPathComponentsForCDParentInTitle);
        if (addParentToCD)
        {
            NSRegularExpression* cdRegex = [NSRegularExpression regularExpressionWithPattern:@"^(CD|Disc)\\s*\\d+$"
                                                                                     options:NSRegularExpressionCaseInsensitive
                                                                                       error:nil];
            NSRange nameRange = NSMakeRange(0, name.length);
            if ([cdRegex firstMatchInString:name options:0 range:nameRange])
            {
                NSString* parent = parts[parts.count - 2];
                if (parent.length > 0)
                {
                    name = [NSString stringWithFormat:@"%@ - %@", parent, name];
                }
            }
        }

        if (!isDisc)
        {
            name = name.humanReadableFileName;
        }
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
            {
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
/// First strips common prefix and suffix on the original titles (e.g. "Michael Jackson - " and ".mp3"). Then strips
/// leading digits and common prefix only on the remainders (no suffix on second pass), then prepends each title's digits back.
/// Results are memoized by title set so repeated calls with the same titles are fast.
+ (NSArray<NSString*>*)displayTitlesByStrippingCommonPrefixSuffix:(NSArray<NSString*>*)titles
{
    if (titles.count < 2)
        return titles;
    static NSCache<NSArray*, NSArray<NSString*>*>* cache;
    static dispatch_once_t cacheOnce;
    dispatch_once(&cacheOnce, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 128;
    });
    NSArray* key = [titles copy];
    NSArray<NSString*>* cached = [cache objectForKey:key];
    if (cached)
        return cached;
    NSCharacterSet* trimSet = titleTrimCharacterSet();
    NSDictionary<NSString*, NSString*>* initialPair = commonPrefixAndSuffixForStrings(titles);
    NSString* initialPrefix = initialPair[@"prefix"] ?: @"";
    NSString* initialSuffix = initialPair[@"suffix"] ?: @"";
    NSMutableArray<NSString*>* working = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString* raw in titles)
    {
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0)
        {
            [working addObject:raw ?: @""];
            continue;
        }
        NSString* s = raw;
        if (initialPrefix.length > 0 && [s hasPrefix:initialPrefix] && s.length > initialPrefix.length)
            s = [s substringFromIndex:initialPrefix.length];
        if (initialSuffix.length > 0 && [s hasSuffix:initialSuffix] && s.length > initialSuffix.length)
            s = [s substringToIndex:s.length - initialSuffix.length];
        s = [s stringByTrimmingCharactersInSet:trimSet];
        [working addObject:s.length > 0 ? s : raw];
    }
    static NSRegularExpression* leadingDigitsRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        leadingDigitsRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\d+" options:0 error:nil];
    });
    NSMutableArray<NSString*>* leadingDigitsList = [NSMutableArray arrayWithCapacity:titles.count];
    NSMutableArray<NSString*>* restList = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString* raw in working)
    {
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0)
        {
            [leadingDigitsList addObject:@""];
            [restList addObject:raw ?: @""];
            continue;
        }
        NSTextCheckingResult* match = [leadingDigitsRegex firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (match)
        {
            [leadingDigitsList addObject:[raw substringWithRange:match.range]];
            [restList addObject:[raw substringFromIndex:NSMaxRange(match.range)]];
        }
        else
        {
            [leadingDigitsList addObject:@""];
            [restList addObject:raw];
        }
    }
    NSDictionary<NSString*, NSString*>* pair = commonPrefixAndSuffixForStrings(restList);
    NSString* commonPrefix = pair[@"prefix"] ?: @"";
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSUInteger i = 0; i < titles.count; i++)
    {
        NSString* raw = titles[i];
        NSString* leadingDigits = leadingDigitsList[i];
        NSString* rest = restList[i];
        if (![raw isKindOfClass:[NSString class]] || raw.length == 0)
        {
            [result addObject:raw ?: @""];
            continue;
        }
        NSString* stripped = rest;
        if (commonPrefix.length > 0 && [stripped hasPrefix:commonPrefix] && stripped.length > commonPrefix.length)
            stripped = [stripped substringFromIndex:commonPrefix.length];
        stripped = [stripped stringByTrimmingCharactersInSet:trimSet];
        NSString* final;
        if (leadingDigits.length > 0)
            final = stripped.length > 0 ? [NSString stringWithFormat:@"%@ %@", leadingDigits, stripped] : leadingDigits;
        else
            final = stripped.length > 0 ? stripped : raw;
        [result addObject:final];
    }
    [cache setObject:result forKey:key];
    return result;
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
        NSString* fileName = @(file.name);
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
        NSString* fileName = @(file.name);
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
        NSString* path = @(file.name);
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
        NSString* fileName = @(file.name);
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
                @"type" : @"file",
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
            NSString* cuePath = [self cueFilePathForFolder:folder];
            if (cuePath.length > 0)
                return cuePath;
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
