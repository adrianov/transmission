// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "NSStringAdditions.h"
#import "NSString+HumanTitle.h"

@interface NSString (PrivateHumanizedTitleHelpers)
- (NSString*)tr_stringByRemovingExtractedYear:(NSString* _Nullable)year yearInterval:(NSString* _Nullable)yearInterval;
- (NSString*)tr_stringByNormalizingTitleSeparators;
- (NSString*)tr_stringByTighteningParentheses;
- (nullable NSString*)tr_earlyYearInterval;
- (BOOL)tr_isCleanHumanTitle;
- (NSString*)tr_stringByRemovingParenMetadataFormat:(NSString* _Nullable* _Nullable)outFormat
                                               year:(NSString* _Nullable* _Nullable)outYear;
- (NSString*)tr_stringByNormalizingBrackets;
- (nullable NSString*)tr_resolutionTag;
- (nullable NSString*)tr_seasonLabel;
- (nullable NSString*)tr_dateTag;
- (nullable NSString*)tr_yearIntervalLabelWithEarly:(NSString* _Nullable)early;
- (nullable NSString*)tr_yearTagAllowingFullDate:(BOOL)hasFullDate
                                        interval:(NSString* _Nullable)yearInterval
                                        metadata:(NSString* _Nullable)metadataYear;
- (NSString*)tr_stringByStrippingTechTags;
- (NSString*)tr_stringByRemovingResolutionTokens;
- (NSString*)tr_stringByCleaningHumanTitleDots:(BOOL)hadGluedDots;
- (NSString*)tr_assembledHumanTitleSeason:(NSString* _Nullable)season
                                     year:(NSString* _Nullable)year
                             yearInterval:(NSString* _Nullable)yearInterval
                                     date:(NSString* _Nullable)date
                               resolution:(NSString* _Nullable)resolution;
- (BOOL)tr_filenameNeedsSeparatorReplace;
- (NSString*)tr_stringByReplacingFilenameSeparators;
- (nullable NSString*)tr_episodePrefixMatchEnd:(NSUInteger*)matchEnd standaloneTitle:(NSString* _Nullable* _Nullable)standalone;
- (NSString*)tr_stringByStrippingEpisodeTechTags;
- (NSString*)tr_stringByRemovingUnbalancedBrackets;
- (NSString*)tr_episodeDisplayTitleWithTorrentName:(NSString* _Nullable)torrentName prefix:(NSString*)prefix;
- (NSRange)tr_enclosingParenRangeForYearAt:(NSRange)yearRange;
- (NSRange)tr_bareYearRemovalRange:(NSRange)yearRange;
- (void)tr_collectParenMetadata:(NSString*)content
                         format:(NSString* _Nullable* _Nullable)extractedFormat
                           year:(NSString* _Nullable* _Nullable)extractedYearFromMetadata;
- (BOOL)tr_isRedundantEpisodeOfTorrentName:(NSString*)torrentName;
- (NSString*)tr_stringByReplacingEpisodeDots;
- (NSString*)tr_filenameCharReplacementAt:(NSUInteger)i;
- (BOOL)tr_isBetweenDigitsAt:(NSUInteger)i;
- (BOOL)tr_isHyphenatedWordAt:(NSUInteger)i;
@end

static NSString* tr_regexReplace(NSString* s, NSString* pattern, NSString* tmpl, NSRegularExpressionOptions opts)
{
    if (s.length == 0)
        return s;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:nil];
    if (re == nil)
        return s;
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:tmpl];
}

static NSTextCheckingResult* tr_regexFirst(NSString* s, NSString* pattern, NSRegularExpressionOptions opts)
{
    if (s.length == 0)
        return nil;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:nil];
    if (re == nil)
        return nil;
    return [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
}

static NSString* tr_regexGroup(NSString* s, NSString* pattern, NSUInteger group, NSRegularExpressionOptions opts)
{
    NSTextCheckingResult* match = tr_regexFirst(s, pattern, opts);
    if (match == nil || (NSUInteger)match.numberOfRanges <= group)
        return nil;
    return [s substringWithRange:[match rangeAtIndex:group]];
}

@implementation NSString (PrivateHumanizedTitle)

- (NSString*)tr_formatHumanTitle
{
    if (self.length == 0)
        return @"Unknown";

    NSString* title = tr_regexReplace(self, @"(?:19|20)\\d{2}(?:\\.{2,}|\u2026)(?:19|20)\\d{2}", @" ", 0);
    NSString* earlyYearInterval = [self tr_earlyYearInterval];
    title = [[title tr_stringByNormalizingTitleSeparators] tr_stringByTighteningParentheses];
    if ([title tr_isCleanHumanTitle])
        return [title tr_stringByTighteningParentheses];

    title = tr_regexReplace(title, @"\\.[a-z0-9]{2,5}$", @"", NSRegularExpressionCaseInsensitive);
    NSString* extractedFormat = nil;
    NSString* extractedYearFromMetadata = nil;
    title = [title tr_stringByRemovingParenMetadataFormat:&extractedFormat year:&extractedYearFromMetadata];
    title = [title tr_stringByNormalizingBrackets];

    NSString* resolution = [title tr_resolutionTag] ?: extractedFormat;
    NSString* season = [title tr_seasonLabel];
    NSString* date = [title tr_dateTag];
    NSString* yearInterval = [title tr_yearIntervalLabelWithEarly:earlyYearInterval];
    BOOL const hasFullDate = tr_regexFirst(title, @"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{4})[\\])]?", 0) != nil;
    NSString* year = [title tr_yearTagAllowingFullDate:hasFullDate interval:yearInterval metadata:extractedYearFromMetadata];
    BOOL const hadGluedDots = tr_regexFirst(title, @"[\\p{L}\\p{N}]+\\.[\\p{L}\\p{N}]+\\.[\\p{L}\\p{N}]+", 0) != nil;

    title = [title tr_stringByStrippingTechTags];
    title = [title tr_stringByRemovingResolutionTokens];
    title = [title tr_stringByRemovingExtractedYear:year yearInterval:yearInterval];
    title = tr_regexReplace(title, @"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{4})[\\])]?", @"", 0);
    title = tr_regexReplace(title, @"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{2})[\\])]?", @"", 0);
    title = [title tr_stringByCleaningHumanTitleDots:hadGluedDots];
    NSString* result = [title tr_assembledHumanTitleSeason:season year:year yearInterval:yearInterval date:date
                                                resolution:resolution];
    return result.length > 0 ? result : self;
}

- (NSString*)tr_formatHumanFileName
{
    if (self.length == 0)
        return @"Unknown";
    NSString* name = self.lastPathComponent;
    if (name.length == 0)
        return @"Unknown";

    name = [name tr_stringByNormalizingTitleSeparators];
    name = tr_regexReplace(name, @"\\(\\s+", @"(", 0);
    name = tr_regexReplace(name, @"\\s+\\)", @")", 0);
    if (![name tr_filenameNeedsSeparatorReplace])
        return name;
    NSString* normalized = [name tr_stringByReplacingFilenameSeparators];
    return normalized.length > 0 ? normalized : name;
}

- (NSString*)tr_formatHumanEpisodeName
{
    NSString* filename = self.lastPathComponent;
    NSString* group1 = tr_regexGroup(filename, @"\\bS(\\d{1,2})[.\\s]?E(\\d{1,3})\\b", 1, NSRegularExpressionCaseInsensitive);
    NSString* group2 = tr_regexGroup(filename, @"\\bS(\\d{1,2})[.\\s]?E(\\d{1,3})\\b", 2, NSRegularExpressionCaseInsensitive);
    if (group1 && group2)
        return [NSString stringWithFormat:@"S%ld E%ld", (long)group1.integerValue, (long)group2.integerValue];
    group1 = tr_regexGroup(filename, @"\\b(\\d{1,2})x(\\d{1,3})\\b", 1, NSRegularExpressionCaseInsensitive);
    group2 = tr_regexGroup(filename, @"\\b(\\d{1,2})x(\\d{1,3})\\b", 2, NSRegularExpressionCaseInsensitive);
    if (group1 && group2)
        return [NSString stringWithFormat:@"S%ld E%ld", (long)group1.integerValue, (long)group2.integerValue];
    NSString* episode = tr_regexGroup(filename, @"\\bE(\\d{1,3})\\b", 1, NSRegularExpressionCaseInsensitive);
    if (episode)
        return [NSString stringWithFormat:@"E%ld", (long)episode.integerValue];
    return nil;
}

- (NSString*)tr_formatHumanEpisodeTitleWithTorrentName:(NSString*)torrentName
{
    NSUInteger matchEnd = NSNotFound;
    NSString* standalone = nil;
    NSString* prefix = [self tr_episodePrefixMatchEnd:&matchEnd standaloneTitle:&standalone];
    if (standalone)
        return standalone;
    if (!prefix)
        return nil;
    NSString* filename = self.lastPathComponent;
    NSString* remaining = matchEnd != NSNotFound && matchEnd <= filename.length ? [filename substringFromIndex:matchEnd] : @"";
    remaining = tr_regexReplace(remaining, @"^[.\\s]+", @"", 0);
    if (remaining.length == 0)
        return prefix;
    remaining = [remaining tr_stringByStrippingEpisodeTechTags];
    remaining = [remaining tr_stringByReplacingEpisodeDots];
    NSString* title = remaining.tr_formatHumanFileName;
    return [title tr_episodeDisplayTitleWithTorrentName:torrentName prefix:prefix];
}

@end

@implementation NSString (PrivateHumanizedTitleHelpers)

- (NSString*)tr_stringByNormalizingTitleSeparators
{
    NSString* name = [self stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"|" withString:@" "];
    name = tr_regexReplace(name, @"\\s+l\\s+", @" ", 0);
    name = [name stringByReplacingOccurrencesOfString:@"," withString:@", "];
    name = tr_regexReplace(name, @"\\s+", @" ", 0);
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (NSString*)tr_stringByTighteningParentheses
{
    NSString* title = tr_regexReplace(self, @"\\(\\s+", @"(", 0);
    title = tr_regexReplace(title, @"\\s+\\)", @")", 0);
    return tr_regexReplace(title, @"([\\p{L}\\p{N}])\\(", @"$1 (", 0);
}

- (NSString*)tr_earlyYearInterval
{
    NSTextCheckingResult* match = tr_regexFirst(self, @"((?:19|20)\\d{2})(?:\\.{2,}|\u2026)((?:19|20)\\d{2})", 0);
    if (match == nil || match.numberOfRanges <= 2)
        return nil;
    NSRange fullRange = [match rangeAtIndex:0];
    NSInteger start = (NSInteger)fullRange.location;
    NSInteger end = (NSInteger)(fullRange.location + fullRange.length);
    BOOL const atWordBoundary = (start == 0 ||
                                 ![[NSCharacterSet decimalDigitCharacterSet]
                                     characterIsMember:[self characterAtIndex:(NSUInteger)(start - 1)]]) &&
        (end >= (NSInteger)self.length ||
         ![[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[self characterAtIndex:(NSUInteger)end]]);
    if (!atWordBoundary)
        return nil;
    NSString* startYear = [self substringWithRange:[match rangeAtIndex:1]];
    NSString* endYear = [self substringWithRange:[match rangeAtIndex:2]];
    return [NSString stringWithFormat:@"%@-%@", startYear, endYear];
}

- (BOOL)tr_isCleanHumanTitle
{
    if (tr_regexFirst(self, @"^[\\p{L}\\p{N}\\s,\\[\\]\\(\\)\\{\\}\\-:;]+$", 0) == nil)
        return NO;
    return tr_regexFirst(self,
                         @"\\b(?:2160p|1080p|720p|480p|8K|4K|UHD|S\\d{1,2}|(?:19|20)\\d{2}|DVD|BD|WEB|Rip|HEVC|H264|H265|x264|x265|AAC|AC3|DTS|FLAC|MP3|Jaskier|MVO|ExKinoRay|RuTracker)\\b",
                         NSRegularExpressionCaseInsensitive) == nil;
}

- (NSString*)tr_stringByRemovingParenMetadataFormat:(NSString**)outFormat year:(NSString**)outYear
{
    static NSRegularExpression* parenMetadataRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        parenMetadataRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(([^)]+)\\)" options:0 error:nil];
    });

    NSString* title = self;
    NSString* extractedFormat = nil;
    NSString* extractedYearFromMetadata = nil;
    NSMutableArray<NSValue*>* rangesToRemove = [NSMutableArray array];
    for (NSTextCheckingResult* match in [parenMetadataRegex matchesInString:title options:0 range:NSMakeRange(0, title.length)])
    {
        if (match.numberOfRanges <= 1)
            continue;
        NSString* content = [title substringWithRange:[match rangeAtIndex:1]];
        if (![content containsString:@","])
            continue;
        [self tr_collectParenMetadata:content format:&extractedFormat year:&extractedYearFromMetadata];
        [rangesToRemove addObject:[NSValue valueWithRange:match.range]];
    }
    for (NSValue* rangeValue in [rangesToRemove reverseObjectEnumerator])
        title = [title stringByReplacingCharactersInRange:rangeValue.rangeValue withString:@" "];
    title = tr_regexReplace(title, @"\\s*,\\s*\\)", @"", 0);
    title = tr_regexReplace(title, @"\\s*,\\s*(LP|CD|EP)\\s*\\)", @"", NSRegularExpressionCaseInsensitive);
    if (outFormat)
        *outFormat = extractedFormat;
    if (outYear)
        *outYear = extractedYearFromMetadata;
    return title;
}

- (void)tr_collectParenMetadata:(NSString*)content format:(NSString**)extractedFormat year:(NSString**)extractedYearFromMetadata
{
    static NSRegularExpression* yearInMetadataRegex = nil;
    static NSRegularExpression* formatTagRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        yearInMetadataRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19\\d{2}|20\\d{2})\\b" options:0 error:nil];
        formatTagRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(LP|CD|EP|DVD|BD|DVD5|DVD9|BD25|BD50|BD66|BD100)\\b"
                                                                   options:NSRegularExpressionCaseInsensitive
                                                                     error:nil];
    });
    for (NSString* part in [content componentsSeparatedByString:@","])
    {
        NSString* trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!*extractedYearFromMetadata)
        {
            NSTextCheckingResult* yearMatch = [yearInMetadataRegex firstMatchInString:trimmed options:0
                                                                                range:NSMakeRange(0, trimmed.length)];
            if (yearMatch)
                *extractedYearFromMetadata = [trimmed substringWithRange:yearMatch.range];
        }
        if (!*extractedFormat)
        {
            NSTextCheckingResult* formatMatch = [formatTagRegex firstMatchInString:trimmed options:0
                                                                             range:NSMakeRange(0, trimmed.length)];
            if (formatMatch)
            {
                NSString* matched = [trimmed substringWithRange:formatMatch.range];
                BOOL const audioDisc = [matched.uppercaseString isEqualToString:@"LP"] ||
                    [matched.uppercaseString isEqualToString:@"CD"] || [matched.uppercaseString isEqualToString:@"EP"];
                *extractedFormat = audioDisc ? matched.lowercaseString : matched.uppercaseString;
            }
        }
        if (*extractedFormat && *extractedYearFromMetadata)
            break;
    }
}

- (NSString*)tr_stringByNormalizingBrackets
{
    NSString* title = tr_regexReplace(self, @"\\{[^}]*\\}", @" ", 0);
    title = [title stringByReplacingOccurrencesOfString:@"[" withString:@" "];
    title = [title stringByReplacingOccurrencesOfString:@"]" withString:@" "];
    title = tr_regexReplace(title, @"\\s{2,}", @" ", 0);
    title = tr_regexReplace(title, @"\\s-\\s-\\s", @" - ", 0);
    title = tr_regexReplace(title, @"(BDRip|HDRip|DVDRip|WEBRip)(1080p|720p|2160p|480p)", @"$1 $2", NSRegularExpressionCaseInsensitive);
    return [title stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

- (NSString*)tr_resolutionTag
{
    NSString* res = tr_regexGroup(self, @"\\b(2160p|1080p|720p|480p)\\b", 1, NSRegularExpressionCaseInsensitive);
    if (res)
        return res;
    NSString* uhd = tr_regexGroup(self, @"\\b(8K|4K|UHD)\\b", 1, NSRegularExpressionCaseInsensitive);
    if (uhd)
        return [uhd.uppercaseString isEqualToString:@"8K"] ? @"8K" : @"2160p";
    NSString* disc = tr_regexGroup(self, @"\\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\\b", 1, NSRegularExpressionCaseInsensitive);
    if (disc)
        return disc.uppercaseString;
    NSString* codec = tr_regexGroup(self, @"\\b(XviD|DivX)\\b", 1, NSRegularExpressionCaseInsensitive);
    if (codec)
        return codec.lowercaseString;
    NSString* audio = tr_regexGroup(self, @"\\b(MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A|LP|CD|EP)\\b", 1, NSRegularExpressionCaseInsensitive);
    if (audio)
        return audio.lowercaseString;
    if (tr_regexFirst(self, @"\\(?(МР3|МРЗ)\\)?", NSRegularExpressionCaseInsensitive))
        return @"mp3";
    return nil;
}

- (NSString*)tr_seasonLabel
{
    NSTextCheckingResult* rangeMatch = tr_regexFirst(self, @"\\bS(\\d{1,2})[-–](\\d{1,2})\\b", NSRegularExpressionCaseInsensitive);
    if (rangeMatch && rangeMatch.numberOfRanges > 2)
    {
        int from = [self substringWithRange:[rangeMatch rangeAtIndex:1]].intValue;
        int to = [self substringWithRange:[rangeMatch rangeAtIndex:2]].intValue;
        return [NSString stringWithFormat:@"Season %d-%d", from, to];
    }
    NSString* seasonNum = tr_regexGroup(self, @"\\bS(\\d{1,2})(?:E\\d+)?\\b", 1, NSRegularExpressionCaseInsensitive);
    if (!seasonNum)
        return nil;
    return [NSString stringWithFormat:@"Season %d", seasonNum.intValue];
}

- (NSString*)tr_dateTag
{
    NSString* full = tr_regexGroup(self, @"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{4})[\\])]?", 1, 0);
    if (full)
        return full;
    return tr_regexGroup(self, @"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{2})[\\])]?", 1, 0);
}

- (NSString*)tr_yearIntervalLabelWithEarly:(NSString*)early
{
    NSTextCheckingResult* hyphen = tr_regexFirst(self, @"\\b((?:19|20)\\d{2})\\s*-\\s*((?:19|20)\\d{2})\\b", 0);
    if (hyphen && hyphen.numberOfRanges > 2)
    {
        NSString* startYear = [self substringWithRange:[hyphen rangeAtIndex:1]];
        NSString* endYear = [self substringWithRange:[hyphen rangeAtIndex:2]];
        return [NSString stringWithFormat:@"%@-%@", startYear, endYear];
    }
    NSTextCheckingResult* ellipsis = tr_regexFirst(self, @"\\b((?:19|20)\\d{2})(?:\\.{2,}|\u2026)((?:19|20)\\d{2})\\b", 0);
    if (ellipsis && ellipsis.numberOfRanges > 2)
    {
        NSString* startYear = [self substringWithRange:[ellipsis rangeAtIndex:1]];
        NSString* endYear = [self substringWithRange:[ellipsis rangeAtIndex:2]];
        return [NSString stringWithFormat:@"%@-%@", startYear, endYear];
    }
    return early;
}

- (NSString*)tr_yearTagAllowingFullDate:(BOOL)hasFullDate interval:(NSString*)yearInterval metadata:(NSString*)metadataYear
{
    if (hasFullDate || yearInterval.length > 0)
        return nil;
    NSString* year = tr_regexGroup(self, @"\\b(19\\d{2}|20\\d{2})\\b", 1, 0);
    return year ?: metadataYear;
}

- (NSString*)tr_stringByStrippingTechTags
{
    NSString* title = tr_regexReplace(self, @"\\b[a-z0-9]+-?rip\\b", @" ", NSRegularExpressionCaseInsensitive);
    title = tr_regexReplace(title, @"\\b[a-z0-9]+HD\\b", @" ", NSRegularExpressionCaseInsensitive);
    title = tr_regexReplace(title, @"\\b[a-z0-9]*-?SbR\\b", @" ", NSRegularExpressionCaseInsensitive);
    NSArray* techTags = @[
        @"WEBDL",   @"WEB-DL",     @"WEBRip",   @"BDRip",   @"BluRay",    @"HDRip",     @"DVDRip",   @"HDTV",    @"WEB-DLRip",
        @"DLRip",   @"HEVC",       @"H264",     @"H.264",   @"H265",      @"H.265",     @"x264",     @"x265",    @"AVC",
        @"10bit",   @"AAC",        @"AAC2.0",   @"AAC5.1",  @"AC3",       @"DD5.1",     @"DD2.0",    @"DD5",     @"DD2",
        @"DDP5.1",  @"DDP2.0",     @"DDP5",     @"DDP2",    @"DTS",       @"DTS-HD",    @"Atmos",    @"TrueHD",  @"FLAC",
        @"EAC3",    @"SDR",        @"HDR",      @"HDR10",   @"DV",        @"DoVi",      @"AMZN",     @"NF",      @"DSNP",
        @"HMAX",    @"PCOK",       @"ATVP",     @"APTV",    @"ExKinoRay", @"RuTracker", @"LostFilm", @"MP4",     @"IMAX",
        @"REPACK",  @"PROPER",     @"EXTENDED", @"UNRATED", @"BDRemux",   @"REMUX",     @"HDCLUB",   @"Jaskier", @"MVO",
        @"180x180", @"180",        @"360",      @"3dh",     @"3dv",       @"LR",        @"TB",       @"SBS",     @"OU",
        @"MKX200",  @"FISHEYE190", @"RF52",     @"VRCA220"
    ];
    for (NSString* tag in techTags)
        title = tr_regexReplace(title, [NSString stringWithFormat:@"\\b%@\\b", tag], @"", NSRegularExpressionCaseInsensitive);
    return title;
}

- (NSString*)tr_stringByRemovingResolutionTokens
{
    NSString* title = tr_regexReplace(self, @"\\.?#?\\b(2160p|1080p|720p|480p)\\b", @"", NSRegularExpressionCaseInsensitive);
    title = tr_regexReplace(title,
                            @"\\.?#?\\(?(\\b(?:8K|4K|UHD|DVD5|DVD9|DVD|BD25|BD50|BD66|BD100|XviD|DivX|MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A|LP|CD|EP)\\b)\\)?",
                            @"",
                            NSRegularExpressionCaseInsensitive);
    title = tr_regexReplace(title, @"\\(?(МР3|МРЗ)\\)?", @"", NSRegularExpressionCaseInsensitive);
    return tr_regexReplace(title, @"\\.?S\\d{1,2}(?:[-–]\\d{1,2})?(?:E\\d+)?\\b", @"", NSRegularExpressionCaseInsensitive);
}

- (NSString*)tr_stringByCleaningHumanTitleDots:(BOOL)hadGluedDots
{
    NSString* title = self;
    BOOL const hasNoSpaces = ![title containsString:@" "];
    if (hadGluedDots || (hasNoSpaces && [title containsString:@"."]))
        title = [title stringByReplacingOccurrencesOfString:@"." withString:@" "];
    NSString* dashPlaceholder = @"\u0000";
    title = tr_regexReplace(title, @"(?:\\s+-\\s*|\\s*-\\s+)+", dashPlaceholder, 0);
    title = tr_regexReplace(title, @"(?:^|\\s)-(?:\\s|$)", @" ", 0);
    title = [title stringByReplacingOccurrencesOfString:dashPlaceholder withString:@" - "];
    title = tr_regexReplace(title, @"\\s+", @" ", 0);
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    title = tr_regexReplace(title, @"\\.\\s+\\.", @". ", 0);
    title = tr_regexReplace(title, @"\\s+\\.(\\w)", @" $1", 0);
    title = tr_regexReplace(title, @"\\s+\\.(\\s|$)", @"$1", 0);
    title = tr_regexReplace(title, @"([^\\.])\\.(\\s*)$", @"$1$2", 0);
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    title = tr_regexReplace(title, @"\\(\\s*\\)", @"", 0);
    title = tr_regexReplace(title, @"\\(\\s*(?:HD|SD)\\s*\\)", @"", NSRegularExpressionCaseInsensitive);
    while ([title hasPrefix:@"-"] || [title hasPrefix:@" "])
        title = [title substringFromIndex:1];
    while ([title hasSuffix:@"-"] || [title hasSuffix:@" "])
        title = [title substringToIndex:title.length - 1];
    return title;
}

- (NSString*)tr_assembledHumanTitleSeason:(NSString*)season
                                     year:(NSString*)year
                             yearInterval:(NSString*)yearInterval
                                     date:(NSString*)date
                               resolution:(NSString*)resolution
{
    NSMutableString* result = [NSMutableString stringWithString:self];
    if (season)
        [result appendFormat:@" - %@", season];
    if (yearInterval)
        [result appendFormat:@" (%@)", yearInterval];
    else if (year && !date)
        [result appendFormat:@" (%@)", year];
    if (date)
        [result appendFormat:@" (%@)", date];
    if (resolution)
        [result appendFormat:@" #%@", resolution];
    return [result tr_stringByTighteningParentheses];
}

- (BOOL)tr_filenameNeedsSeparatorReplace
{
    NSUInteger whitespaceCount = 0, dotCount = 0, hyphenCount = 0, underscoreCount = 0;
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i = 0; i < self.length; ++i)
    {
        unichar const c = [self characterAtIndex:i];
        if ([whitespace characterIsMember:c])
            ++whitespaceCount;
        else if (c == '.')
            ++dotCount;
        else if (c == '-')
            ++hyphenCount;
        else if (c == '_')
            ++underscoreCount;
    }
    NSUInteger const separatorCount = dotCount + hyphenCount + underscoreCount;
    BOOL const noSpaces = whitespaceCount == 0;
    return (separatorCount >= 3 && separatorCount > whitespaceCount) ||
        (noSpaces && (underscoreCount > 0 || dotCount >= 2 || hyphenCount >= 2));
}

- (BOOL)tr_isBetweenDigitsAt:(NSUInteger)i
{
    if (i == 0 || i + 1 >= self.length)
        return NO;
    NSCharacterSet* digits = NSCharacterSet.decimalDigitCharacterSet;
    return [digits characterIsMember:[self characterAtIndex:i - 1]] && [digits characterIsMember:[self characterAtIndex:i + 1]];
}

- (BOOL)tr_isHyphenatedWordAt:(NSUInteger)i
{
    if (i == 0 || i + 1 >= self.length)
        return NO;
    NSCharacterSet* letters = NSCharacterSet.letterCharacterSet;
    return [letters characterIsMember:[self characterAtIndex:i - 1]] && [letters characterIsMember:[self characterAtIndex:i + 1]];
}

- (NSString*)tr_filenameCharReplacementAt:(NSUInteger)i
{
    unichar const c = [self characterAtIndex:i];
    if (c == '_')
        return @" ";
    if (c == '.')
        return [self tr_isBetweenDigitsAt:i] ? @"." : @" ";
    if (c != '-')
        return [NSString stringWithFormat:@"%C", c];
    unichar const prev = i > 0 ? [self characterAtIndex:i - 1] : 0;
    unichar const next = i + 1 < self.length ? [self characterAtIndex:i + 1] : 0;
    if ([self tr_isBetweenDigitsAt:i] || (prev == ' ' && next == ' ') || [self tr_isHyphenatedWordAt:i])
        return @"-";
    return @" ";
}

- (NSString*)tr_stringByReplacingFilenameSeparators
{
    NSMutableString* out = [NSMutableString stringWithCapacity:self.length];
    for (NSUInteger i = 0; i < self.length; ++i)
        [out appendString:[self tr_filenameCharReplacementAt:i]];
    NSArray<NSString*>* parts = [out nonEmptyComponentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [parts componentsJoinedByString:@" "];
}

- (NSString*)tr_episodePrefixMatchEnd:(NSUInteger*)matchEnd standaloneTitle:(NSString**)standalone
{
    NSString* filename = self.lastPathComponent;
    NSTextCheckingResult* seMatch = tr_regexFirst(filename, @"\\bS(\\d{1,2})[.\\s]?E(\\d{1,3})\\b", NSRegularExpressionCaseInsensitive);
    if (seMatch && seMatch.numberOfRanges >= 3)
    {
        NSInteger season = [[filename substringWithRange:[seMatch rangeAtIndex:1]] integerValue];
        NSInteger episode = [[filename substringWithRange:[seMatch rangeAtIndex:2]] integerValue];
        *matchEnd = seMatch.range.location + seMatch.range.length;
        *standalone = nil;
        return [NSString stringWithFormat:@"S%ld E%ld", (long)season, (long)episode];
    }
    NSTextCheckingResult* altMatch = tr_regexFirst(filename, @"\\b(\\d{1,2})x(\\d{1,3})\\b", NSRegularExpressionCaseInsensitive);
    if (altMatch && altMatch.numberOfRanges >= 3)
    {
        NSInteger season = [[filename substringWithRange:[altMatch rangeAtIndex:1]] integerValue];
        NSInteger episode = [[filename substringWithRange:[altMatch rangeAtIndex:2]] integerValue];
        *matchEnd = altMatch.range.location + altMatch.range.length;
        *standalone = nil;
        return [NSString stringWithFormat:@"S%ld E%ld", (long)season, (long)episode];
    }
    if (tr_regexFirst(filename, @"\\b(?:S?\\d{1,2})?E(\\d{1,3})\\b", NSRegularExpressionCaseInsensitive) == nil)
        return nil;
    NSString* base = filename.stringByDeletingPathExtension;
    *standalone = base.length > 0 ? base.tr_formatHumanFileName : nil;
    *matchEnd = NSNotFound;
    return nil;
}

- (NSString*)tr_stringByStrippingEpisodeTechTags
{
    NSString* remaining = tr_regexReplace(self, @"\\b[a-z0-9]+-?rip\\b", @" ", NSRegularExpressionCaseInsensitive);
    remaining = tr_regexReplace(remaining, @"\\b[a-z0-9]+HD\\b", @" ", NSRegularExpressionCaseInsensitive);
    remaining = tr_regexReplace(remaining, @"\\b[a-z0-9]*-?SbR\\b", @" ", NSRegularExpressionCaseInsensitive);
    NSArray* tagsToStrip = @[
        @"1080p",   @"720p",    @"2160p",  @"480p",   @"8K",     @"4K",     @"UHD",       @"WEB-DL", @"WEBDL",  @"WEBRip",
        @"BDRip",   @"BDRemux", @"BluRay", @"HDRip",  @"DVDRip", @"HDTV",   @"WEB-DLRip", @"DLRip",  @"H264",   @"H.264",
        @"H265",    @"H.265",   @"x264",   @"x265",   @"HEVC",   @"AVC",    @"AMZN",      @"NF",     @"DSNP",   @"HMAX",
        @"PCOK",    @"ATVP",    @"APTV",   @"2xRu",   @"Ru",     @"En",     @"qqss44",    @"WEB",    @"DL",     @"DD5.1",
        @"DD2.0",   @"DD5",     @"DD2",    @"DDP5.1", @"DDP2.0", @"DDP5",   @"DDP2",      @"Atmos",  @"TrueHD", @"DTS",
        @"DTS-HD",  @"EAC3",    @"EAC",    @"AC3",    @"AAC",    @"AAC2.0", @"AAC5.1",    @"PROPER", @"REPACK", @"EXTENDED",
        @"UNRATED", @"REMUX",   @"10bit",  @"HDR",    @"HDR10",  @"DV",     @"DoVi",      @"SDR",    @"IMAX"
    ];
    for (NSString* tag in tagsToStrip)
    {
        NSString* pattern = [NSString stringWithFormat:@"\\b%@\\b", [NSRegularExpression escapedPatternForString:tag]];
        remaining = tr_regexReplace(remaining, pattern, @" ", NSRegularExpressionCaseInsensitive);
    }
    remaining = tr_regexReplace(remaining, @"\\.(mkv|mp4|avi|mov|wmv|flv|webm|m4v|mpg|mpeg|ts|m2ts)$", @"", NSRegularExpressionCaseInsensitive);
    remaining = tr_regexReplace(remaining, @"\\s+", @" ", 0);
    return [remaining stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (NSString*)tr_stringByRemovingUnbalancedBrackets
{
    NSMutableString* cleaned = [NSMutableString stringWithCapacity:self.length];
    NSInteger parenDepth = 0, bracketDepth = 0;
    for (NSUInteger ci = 0; ci < self.length; ci++)
    {
        unichar ch = [self characterAtIndex:ci];
        if (ch == '(')
            parenDepth++;
        else if (ch == ')')
        {
            if (parenDepth <= 0)
                continue;
            parenDepth--;
        }
        else if (ch == '[')
            bracketDepth++;
        else if (ch == ']')
        {
            if (bracketDepth <= 0)
                continue;
            bracketDepth--;
        }
        [cleaned appendFormat:@"%C", ch];
    }
    return cleaned;
}

- (NSString*)tr_episodeDisplayTitleWithTorrentName:(NSString*)torrentName prefix:(NSString*)prefix
{
    NSString* title = tr_regexReplace(self, @"[\\[\\(]\\s*[\\]\\)]", @"", 0);
    title = [title tr_stringByRemovingUnbalancedBrackets];
    title = [title stringByReplacingOccurrencesOfString:@"|" withString:@""];
    title = tr_regexReplace(title, @"\\s+l\\s+", @" ", 0);
    title = [title stringByReplacingOccurrencesOfString:@"," withString:@", "];
    title = tr_regexReplace(title, @"\\s+", @" ", 0);
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSCharacterSet* trimSet = [NSCharacterSet characterSetWithCharactersInString:@". "];
    title = [title stringByTrimmingCharactersInSet:trimSet];
    if ([title.lowercaseString hasSuffix:@"mkv"])
    {
        title = [title substringToIndex:title.length - 3];
        title = [title stringByTrimmingCharactersInSet:trimSet];
    }
    if (title.length <= 1)
        return prefix;
    if (torrentName && [title tr_isRedundantEpisodeOfTorrentName:torrentName])
        return prefix;
    return [NSString stringWithFormat:@"%@ - %@", prefix, title];
}

- (BOOL)tr_isRedundantEpisodeOfTorrentName:(NSString*)torrentName
{
    NSString* humanTorrentName = torrentName.tr_formatHumanTitle;
    NSString* baseTorrentName = tr_regexReplace(humanTorrentName, @"\\s*(- Season \\d+|\\(\\d{4}\\)|#\\d+p|#\\w+)", @"", 0);
    if ([self.lowercaseString isEqualToString:baseTorrentName.lowercaseString])
        return YES;
    NSString* titleWithoutYear = tr_regexReplace(self, @"\\s*\\(?\\b(19|20)\\d{2}\\b\\)?", @"", 0);
    return [titleWithoutYear.lowercaseString isEqualToString:baseTorrentName.lowercaseString];
}

- (NSRange)tr_enclosingParenRangeForYearAt:(NSRange)yearRange
{
    NSCharacterSet* spaces = NSCharacterSet.whitespaceCharacterSet;
    NSInteger start = (NSInteger)yearRange.location;
    NSInteger parenStart = NSNotFound;
    NSInteger i = start - 1;
    while (i >= 0)
    {
        unichar c = [self characterAtIndex:(NSUInteger)i];
        if ([spaces characterIsMember:c])
        {
            i--;
            continue;
        }
        if (c == '(')
        {
            NSRange between = NSMakeRange((NSUInteger)(i + 1), (NSUInteger)(start - (i + 1)));
            if ([self rangeOfString:@")" options:0 range:between].location == NSNotFound)
                parenStart = i;
        }
        break;
    }
    if (parenStart == NSNotFound)
        return NSMakeRange(NSNotFound, 0);
    NSInteger depth = 1;
    NSInteger j = parenStart + 1;
    NSInteger len = (NSInteger)self.length;
    while (j < len && depth > 0)
    {
        unichar c = [self characterAtIndex:(NSUInteger)j];
        if (c == '(')
            depth++;
        else if (c == ')')
            depth--;
        j++;
    }
    if (depth != 0)
        return NSMakeRange(NSNotFound, 0);
    NSInteger parenEnd = j - 1;
    return NSMakeRange((NSUInteger)parenStart, (NSUInteger)(parenEnd - parenStart + 1));
}

- (NSRange)tr_bareYearRemovalRange:(NSRange)yearRange
{
    NSInteger start = (NSInteger)yearRange.location;
    NSInteger end = (NSInteger)(yearRange.location + yearRange.length);
    NSInteger len = (NSInteger)self.length;
    NSInteger removeStart = start;
    NSInteger removeEnd = end;
    if (removeStart > 0 && [self characterAtIndex:(NSUInteger)(removeStart - 1)] == '(' && removeEnd < len &&
        [self characterAtIndex:(NSUInteger)removeEnd] == ')')
    {
        removeStart--;
        removeEnd++;
    }
    else if (removeStart > 0 && [self characterAtIndex:(NSUInteger)(removeStart - 1)] == '.')
        removeStart--;
    if (removeStart == 0 && removeEnd < len)
    {
        while (removeEnd < len &&
               ([self characterAtIndex:(NSUInteger)removeEnd] == '.' || [self characterAtIndex:(NSUInteger)removeEnd] == ' '))
            removeEnd++;
    }
    return NSMakeRange((NSUInteger)removeStart, (NSUInteger)(removeEnd - removeStart));
}

- (NSString*)tr_stringByRemovingOneYear:(NSString*)year
{
    if (year.length == 0)
        return self;
    NSMutableString* result = [self mutableCopy];
    while (YES)
    {
        NSRange yearRange = [result rangeOfString:year];
        if (yearRange.location == NSNotFound)
            break;
        NSRange paren = [result tr_enclosingParenRangeForYearAt:yearRange];
        if (paren.location != NSNotFound)
        {
            [result deleteCharactersInRange:paren];
            continue;
        }
        [result deleteCharactersInRange:[result tr_bareYearRemovalRange:yearRange]];
    }
    return [result copy];
}

- (NSString*)tr_stringByRemovingExtractedYear:(NSString*)year yearInterval:(NSString*)yearInterval
{
    NSString* result = self;
    if (yearInterval.length > 0)
    {
        result = tr_regexReplace(result, @"\\.?\\(?(?:19|20)\\d{2}\\s*-\\s*(?:19|20)\\d{2}\\)?", @"", 0);
        result = tr_regexReplace(result, @"(?:19|20)\\d{2}(?:\\.{2,}|\u2026)(?:19|20)\\d{2}", @"", 0);
        result = tr_regexReplace(result, @"\\b(?:19|20)\\d{2}\\.{2,}", @"", 0);
    }
    if (year.length > 0)
        result = [result tr_stringByRemovingOneYear:year];
    return result;
}

- (NSString*)tr_stringByReplacingEpisodeDots
{
    NSMutableString* dotCleaned = [NSMutableString stringWithCapacity:self.length];
    NSCharacterSet* digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSUInteger i = 0; i < self.length; i++)
    {
        unichar c = [self characterAtIndex:i];
        if (c != '.')
        {
            [dotCleaned appendFormat:@"%C", c];
            continue;
        }
        unichar prev = i > 0 ? [self characterAtIndex:i - 1] : 0;
        unichar next = i + 1 < self.length ? [self characterAtIndex:i + 1] : 0;
        BOOL betweenDigits = [digits characterIsMember:prev] && [digits characterIsMember:next];
        [dotCleaned appendString:betweenDigits ? @"." : @" "];
    }
    NSString* remaining = tr_regexReplace(dotCleaned, @"\\s+", @" ", 0);
    return [remaining stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

@end
