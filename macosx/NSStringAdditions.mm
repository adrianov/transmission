// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>
#include <libtransmission/utils.h>

#import "NSStringAdditions.h"
#import "NSDataAdditions.h"

@interface NSString (Private)

+ (NSString*)stringForSpeed:(CGFloat)speed kb:(NSString*)kb mb:(NSString*)mb gb:(NSString*)gb;
+ (NSString*)stringForSpeedCompact:(CGFloat)speed kb:(NSString*)kb mb:(NSString*)mb gb:(NSString*)gb;

@end

@implementation NSString (NSStringAdditions)

+ (NSString*)ellipsis
{
    return @"\xE2\x80\xA6";
}

- (NSString*)stringByAppendingEllipsis
{
    return [self stringByAppendingString:NSString.ellipsis];
}

// Maximum supported localization is 9.22 EB, which is the maximum supported filesystem size by macOS, 8 EiB.
// https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/VolumeFormatComparison/VolumeFormatComparison.html
+ (NSString*)stringForFileSize:(uint64_t)size
{
    return [NSByteCountFormatter stringFromByteCount:size countStyle:NSByteCountFormatterCountStyleFile];
}

// Maximum supported localization is 9.22 EB, which is the maximum supported filesystem size by macOS, 8 EiB.
// https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/VolumeFormatComparison/VolumeFormatComparison.html
+ (NSString*)stringForFilePartialSize:(uint64_t)partialSize fullSize:(uint64_t)fullSize
{
    NSByteCountFormatter* fileSizeFormatter = [[NSByteCountFormatter alloc] init];

    NSString* fullSizeString = [fileSizeFormatter stringFromByteCount:fullSize];

    //figure out the magnitude of the two, since we can't rely on comparing the units because of localization and pluralization issues (for example, "1 byte of 2 bytes")
    BOOL partialUnitsSame;
    if (partialSize == 0)
    {
        partialUnitsSame = YES; //we want to just show "0" when we have no partial data, so always set to the same units
    }
    else
    {
        auto const magnitudePartial = static_cast<unsigned int>(log(partialSize) / log(1000));
        // we have to catch 0 with a special case, so might as well avoid the math for all of magnitude 0
        auto const magnitudeFull = static_cast<unsigned int>(fullSize < 1000 ? 0 : log(fullSize) / log(1000));
        partialUnitsSame = magnitudePartial == magnitudeFull;
    }

    fileSizeFormatter.includesUnit = !partialUnitsSame;
    NSString* partialSizeString = [fileSizeFormatter stringFromByteCount:partialSize];

    return [NSString stringWithFormat:NSLocalizedString(@"%@ of %@", "file size string"), partialSizeString, fullSizeString];
}

+ (NSString*)stringForSpeed:(CGFloat)speed
{
    return [self stringForSpeed:speed kb:NSLocalizedString(@"KB/s", "Transfer speed (kilobytes per second)")
                             mb:NSLocalizedString(@"MB/s", "Transfer speed (megabytes per second)")
                             gb:NSLocalizedString(@"GB/s", "Transfer speed (gigabytes per second)")];
}

+ (NSString*)stringForSpeedAbbrev:(CGFloat)speed
{
    return [self stringForSpeed:speed kb:@"K" mb:@"M" gb:@"G"];
}

+ (NSString*)stringForSpeedAbbrevCompact:(CGFloat)speed
{
    return [self stringForSpeedCompact:speed kb:@"K" mb:@"M" gb:@"G"];
}

+ (NSString*)stringForRatio:(CGFloat)ratio
{
    //N/A is different than libtransmission's

    if (static_cast<int>(ratio) == TR_RATIO_NA)
    {
        return NSLocalizedString(@"N/A", "No Ratio");
    }

    if (static_cast<int>(ratio) == TR_RATIO_INF)
    {
        return @"\xE2\x88\x9E";
    }

    if (ratio < 10.0)
    {
        return [NSString localizedStringWithFormat:@"%.2f", tr_truncd(ratio, 2)];
    }

    if (ratio < 100.0)
    {
        return [NSString localizedStringWithFormat:@"%.1f", tr_truncd(ratio, 1)];
    }

    return [NSString localizedStringWithFormat:@"%.0f", tr_truncd(ratio, 0)];
}

+ (NSString*)percentString:(CGFloat)progress longDecimals:(BOOL)longDecimals
{
    static NSNumberFormatter* longFormatter;
    static NSNumberFormatter* shortFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        longFormatter = [[NSNumberFormatter alloc] init];
        longFormatter.numberStyle = NSNumberFormatterPercentStyle;
        longFormatter.maximumFractionDigits = 2;
        shortFormatter = [[NSNumberFormatter alloc] init];
        shortFormatter.numberStyle = NSNumberFormatterPercentStyle;
        shortFormatter.maximumFractionDigits = 1;
    });
    if (progress >= 1.0)
    {
        return [shortFormatter stringFromNumber:@(1)];
    }
    else if (longDecimals)
    {
        return [longFormatter stringFromNumber:@(MIN(progress, 0.9999))];
    }
    else
    {
        return [shortFormatter stringFromNumber:@(MIN(progress, 0.999))];
    }
}

- (NSComparisonResult)compareNumeric:(NSString*)string
{
    NSStringCompareOptions const comparisonOptions = NSNumericSearch | NSForcedOrderingSearch;
    return [self compare:string options:comparisonOptions range:NSMakeRange(0, self.length) locale:NSLocale.currentLocale];
}

- (NSArray<NSString*>*)nonEmptyComponentsSeparatedByCharactersInSet:(NSCharacterSet*)separators
{
    NSMutableArray<NSString*>* components = [NSMutableArray array];
    for (NSString* evaluatedObject in [self componentsSeparatedByCharactersInSet:separators])
    {
        if (evaluatedObject.length > 0)
        {
            [components addObject:evaluatedObject];
        }
    }
    return components;
}

+ (NSString*)convertedStringFromCString:(nonnull char const*)bytes
{
    // UTF-8 encoding
    NSString* fullPath = @(bytes);
    if (fullPath)
    {
        return fullPath;
    }
    // autodetection of the encoding (#3434)
    NSData* data = [NSData dataWithBytes:(void const*)bytes length:sizeof(unsigned char) * strlen(bytes)];
    [NSString stringEncodingForData:data encodingOptions:nil convertedString:&fullPath usedLossyConversion:nil];
    if (fullPath)
    {
        return fullPath;
    }
    // hexa encoding
    return data.hexString;
}

- (NSString*)humanReadableTitle
{
    if (self.length == 0)
    {
        return @"Unknown";
    }

    NSString* title = self;

    // Remove file extension
    NSArray* extensions = @[ @"mkv", @"avi", @"mp4", @"mov", @"wmv", @"flv", @"webm", @"m4v", @"torrent" ];
    for (NSString* ext in extensions)
    {
        NSString* dotExt = [@"." stringByAppendingString:ext];
        if ([title.lowercaseString hasSuffix:dotExt])
        {
            title = [title substringToIndex:title.length - dotExt.length];
            break;
        }
    }

    // Extract year and format from square bracket metadata like [2006, Documentary, DVD5]
    // Keep content descriptors (Documentary, etc.), only extract year and disc format
    NSString* bracketYear = nil;
    NSString* bracketFormat = nil;
    NSRegularExpression* bracketRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]+)\\]" options:0 error:nil];
    NSTextCheckingResult* bracketMatch = [bracketRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
    if (bracketMatch && bracketMatch.numberOfRanges > 1)
    {
        NSString* bracketContent = [title substringWithRange:[bracketMatch rangeAtIndex:1]];

        // Extract year from brackets
        NSRegularExpression* yearInBracketRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19\\d{2}|20\\d{2})\\b"
                                                                                            options:0
                                                                                              error:nil];
        NSTextCheckingResult* yearInBracketMatch = [yearInBracketRegex firstMatchInString:bracketContent options:0
                                                                                    range:NSMakeRange(0, bracketContent.length)];
        if (yearInBracketMatch)
        {
            bracketYear = [bracketContent substringWithRange:yearInBracketMatch.range];
        }

        // Extract disc format from brackets
        NSRegularExpression* formatInBracketRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\\b"
                                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                                error:nil];
        NSTextCheckingResult* formatInBracketMatch = [formatInBracketRegex firstMatchInString:bracketContent options:0
                                                                                        range:NSMakeRange(0, bracketContent.length)];
        if (formatInBracketMatch)
        {
            bracketFormat = [bracketContent substringWithRange:formatInBracketMatch.range].uppercaseString;
        }

        // Remove only year and disc format from bracket content, keep the rest
        NSString* cleanedBracket = bracketContent;
        cleanedBracket = [yearInBracketRegex stringByReplacingMatchesInString:cleanedBracket options:0
                                                                        range:NSMakeRange(0, cleanedBracket.length)
                                                                 withTemplate:@""];
        cleanedBracket = [formatInBracketRegex stringByReplacingMatchesInString:cleanedBracket options:0
                                                                          range:NSMakeRange(0, cleanedBracket.length)
                                                                   withTemplate:@""];
        // Clean up commas and whitespace
        cleanedBracket = [cleanedBracket stringByReplacingOccurrencesOfString:@"  " withString:@" "];
        cleanedBracket = [cleanedBracket stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]];

        // If bracket still has content, keep it; otherwise remove brackets entirely
        if (cleanedBracket.length > 0)
        {
            title = [title
                stringByReplacingOccurrencesOfString:bracketMatch.range.length > 0 ? [title substringWithRange:bracketMatch.range] : @""
                                          withString:[NSString stringWithFormat:@"[%@]", cleanedBracket]];
        }
        else
        {
            title = [bracketRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                      withTemplate:@" "];
        }
    }

    // Handle merged resolution patterns like "BDRip1080p" -> "BDRip 1080p"
    NSRegularExpression* mergedResRegex = [NSRegularExpression regularExpressionWithPattern:@"(BDRip|HDRip|DVDRip|WEBRip)(1080p|720p|2160p|480p)"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    title = [mergedResRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                withTemplate:@"$1 $2"];

    // Normalize underscore before resolution (e.g., "_1080p" -> " 1080p")
    title = [title stringByReplacingOccurrencesOfString:@"_" withString:@" "];

    // Extract resolution
    NSRegularExpression* resRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(2160p|1080p|720p|480p)\\b"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    NSTextCheckingResult* resMatch = [resRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
    NSString* resolution = resMatch ? [title substringWithRange:resMatch.range] : nil;

    // Check for 8K/4K/UHD if no standard resolution found
    if (!resolution)
    {
        NSRegularExpression* uhdRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(8K|4K|UHD)\\b"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        NSTextCheckingResult* uhdMatch = [uhdRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        if (uhdMatch)
        {
            NSString* matched = [title substringWithRange:uhdMatch.range].uppercaseString;
            resolution = [matched isEqualToString:@"8K"] ? @"8K" : @"2160p";
        }
    }

    // Check for DVD/BD format tags (shown as #DVD5, #BD50, etc.)
    if (!resolution)
    {
        NSRegularExpression* discRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\\b"
                                                                                   options:NSRegularExpressionCaseInsensitive
                                                                                     error:nil];
        NSTextCheckingResult* discMatch = [discRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        if (discMatch)
        {
            resolution = [title substringWithRange:discMatch.range].uppercaseString;
        }
    }

    // Use format extracted from brackets if no other resolution found
    if (!resolution && bracketFormat)
    {
        resolution = bracketFormat;
    }

    // Extract season (S01, S02, etc.)
    NSRegularExpression* seasonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bS(\\d{1,2})(?:E\\d+)?\\b"
                                                                                 options:NSRegularExpressionCaseInsensitive
                                                                                   error:nil];
    NSTextCheckingResult* seasonMatch = [seasonRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
    NSString* season = nil;
    if (seasonMatch && seasonMatch.numberOfRanges > 1)
    {
        NSString* seasonNum = [title substringWithRange:[seasonMatch rangeAtIndex:1]];
        season = [NSString stringWithFormat:@"Season %d", seasonNum.intValue];
    }

    // Extract date pattern DD.MM.YYYY (e.g., 25.10.2021) - check BEFORE year to avoid partial match
    // Also match dates wrapped in parentheses like (25.10.2021)
    NSRegularExpression* fullDateRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(?(\\d{2}\\.\\d{2}\\.\\d{4})\\)?"
                                                                                   options:0
                                                                                     error:nil];
    NSTextCheckingResult* fullDateMatch = [fullDateRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];

    // Extract date pattern YY.MM.DD (e.g., 25.04.14)
    NSRegularExpression* shortDateRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(?(\\d{2}\\.\\d{2}\\.\\d{2})\\)?"
                                                                                    options:0
                                                                                      error:nil];
    NSTextCheckingResult* shortDateMatch = [shortDateRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];

    // Use full date if found, otherwise short date
    // Extract just the date part (group 1), not the parentheses
    NSTextCheckingResult* dateMatch = fullDateMatch ?: shortDateMatch;
    NSString* date = nil;
    NSUInteger dateIndex = NSNotFound;
    if (dateMatch && dateMatch.numberOfRanges > 1)
    {
        date = [title substringWithRange:[dateMatch rangeAtIndex:1]];
        dateIndex = dateMatch.range.location;
    }

    // Extract year (1900-2099) - but not if it's part of a date
    // Also use year extracted from bracket metadata if no other year found
    NSString* year = nil;
    if (!fullDateMatch)
    {
        NSRegularExpression* yearRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19\\d{2}|20\\d{2})\\b" options:0
                                                                                     error:nil];
        NSTextCheckingResult* yearMatch = [yearRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        year = yearMatch ? [title substringWithRange:yearMatch.range] : nil;
    }
    if (!year && bracketYear)
    {
        year = bracketYear;
    }

    // Technical tags to remove
    NSArray* techTags = @[
        // Video sources
        @"WEBDL",
        @"WEB-DL",
        @"WEBRip",
        @"BDRip",
        @"BluRay",
        @"HDRip",
        @"DVDRip",
        @"HDTV",
        // Codecs
        @"HEVC",
        @"H264",
        @"H.264",
        @"H265",
        @"H.265",
        @"x264",
        @"x265",
        @"AVC",
        @"10bit",
        // Audio
        @"AAC",
        @"AC3",
        @"DTS",
        @"Atmos",
        @"TrueHD",
        @"FLAC",
        @"EAC3",
        // HDR
        @"SDR",
        @"HDR",
        @"HDR10",
        @"DV",
        @"DoVi",
        // Sources
        @"AMZN",
        @"NF",
        @"DSNP",
        @"HMAX",
        @"PCOK",
        @"ATVP",
        @"APTV",
        // Other
        @"ExKinoRay",
        @"RuTracker",
        @"LostFilm",
        @"MP4",
        @"IMAX",
        @"REPACK",
        @"PROPER",
        @"EXTENDED",
        @"UNRATED",
        @"REMUX",
        // VR/3D format tags (technical, not content descriptors)
        @"180x180",
        @"180",
        @"360",
        @"3dh",
        @"3dv",
        @"LR",
        @"TB",
        @"SBS",
        @"OU",
        @"MKX200",
        @"FISHEYE190",
        @"RF52",
        @"VRCA220"
    ];

    // Remove tech tags (and preceding dot if used as separator)
    for (NSString* tag in techTags)
    {
        NSString* pattern = [NSString stringWithFormat:@"\\.?%@\\b", tag];
        NSRegularExpression* tagRegex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        title = [tagRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    }

    // Remove resolution, season markers, year, date from title (and preceding dot if used as separator)
    NSRegularExpression* resRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?(2160p|1080p|720p|480p)\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    title = [resRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    NSRegularExpression* uhdRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?(8K|4K|UHD|DVD5|DVD9|DVD|BD25|BD50|BD66|BD100)\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    title = [uhdRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    NSRegularExpression* seasonRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?S\\d{1,2}(E\\d+)?\\b"
                                                                                       options:NSRegularExpressionCaseInsensitive
                                                                                         error:nil];
    title = [seasonRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    if (year)
    {
        NSRegularExpression* yearRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?(19\\d{2}|20\\d{2})\\b"
                                                                                         options:0
                                                                                           error:nil];
        title = [yearRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                     withTemplate:@""];
    }
    // Remove both date formats
    title = [fullDateRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    title = [shortDateRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    // Only replace dots with spaces if title uses dots as separators (no spaces)
    BOOL hasDotSeparators = ![title containsString:@" "] && [title containsString:@"."];
    if (hasDotSeparators)
    {
        title = [title stringByReplacingOccurrencesOfString:@"." withString:@" "];
    }

    // Normalize separators, preserve existing " - "
    title = [title stringByReplacingOccurrencesOfString:@" - " withString:@"\u0000"];
    title = [title stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    title = [title stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    title = [title stringByReplacingOccurrencesOfString:@"\u0000" withString:@" - "];

    // Collapse multiple spaces
    NSRegularExpression* spaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    title = [spaceRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

    // Clean up dots after all removals: "Paris. .Bonus" -> "Paris. Bonus", "Paris .Bonus" -> "Paris Bonus"
    // Preserve "..." ellipsis
    NSRegularExpression* dotSpaceDotRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.\\s+\\." options:0 error:nil];
    title = [dotSpaceDotRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@". "];
    NSRegularExpression* spaceDotWordRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+\\.(\\w)" options:0 error:nil];
    title = [spaceDotWordRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                   withTemplate:@" $1"];
    NSRegularExpression* orphanDotRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+\\.(\\s|$)" options:0 error:nil];
    title = [orphanDotRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@"$1"];
    NSRegularExpression* trailingSingleDotRegex = [NSRegularExpression regularExpressionWithPattern:@"([^\\.])\\.(\\s*)$" options:0
                                                                                              error:nil];
    title = [trailingSingleDotRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                        withTemplate:@"$1$2"];
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

    // Remove leading/trailing hyphens and spaces (but not dots - they may be ellipsis)
    while ([title hasPrefix:@"-"] || [title hasPrefix:@" "])
    {
        title = [title substringFromIndex:1];
    }
    while ([title hasSuffix:@"-"] || [title hasSuffix:@" "])
    {
        title = [title substringToIndex:title.length - 1];
    }

    // Build final title
    NSMutableString* result = [NSMutableString stringWithString:title];

    if (season)
    {
        [result appendFormat:@" - %@", season];
    }
    if (year && !date)
    {
        [result appendFormat:@" (%@)", year];
    }
    if (date)
    {
        [result appendFormat:@" (%@)", date];
    }
    if (resolution)
    {
        [result appendFormat:@" #%@", resolution];
    }

    return result.length > 0 ? result : self;
}

- (NSString*)humanReadableEpisodeName
{
    NSString* filename = self.lastPathComponent;

    // Try S01E05 or S1E5 pattern (most common for TV shows)
    NSRegularExpression* seasonEpisodeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bS(\\d{1,2})[.\\s]?E(\\d{1,2})\\b"
                                                                                        options:NSRegularExpressionCaseInsensitive
                                                                                          error:nil];
    NSTextCheckingResult* seMatch = [seasonEpisodeRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (seMatch && seMatch.numberOfRanges >= 3)
    {
        NSInteger season = [[filename substringWithRange:[seMatch rangeAtIndex:1]] integerValue];
        NSInteger episode = [[filename substringWithRange:[seMatch rangeAtIndex:2]] integerValue];
        return [NSString stringWithFormat:@"Season %ld, Episode %ld", (long)season, (long)episode];
    }

    // Try 1x05 pattern (alternative TV format)
    NSRegularExpression* altSeasonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(\\d{1,2})x(\\d{1,2})\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    NSTextCheckingResult* altMatch = [altSeasonRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (altMatch && altMatch.numberOfRanges >= 3)
    {
        NSInteger season = [[filename substringWithRange:[altMatch rangeAtIndex:1]] integerValue];
        NSInteger episode = [[filename substringWithRange:[altMatch rangeAtIndex:2]] integerValue];
        return [NSString stringWithFormat:@"Season %ld, Episode %ld", (long)season, (long)episode];
    }

    // No episode pattern found - return nil to use humanized filename instead
    return nil;
}

- (NSArray<NSNumber*>*)episodeNumbers
{
    NSString* filename = self.lastPathComponent;

    // Try S01E05 or S1E5 pattern
    NSRegularExpression* seasonEpisodeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bS(\\d{1,2})[.\\s]?E(\\d{1,2})\\b"
                                                                                        options:NSRegularExpressionCaseInsensitive
                                                                                          error:nil];
    NSTextCheckingResult* seMatch = [seasonEpisodeRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (seMatch && seMatch.numberOfRanges >= 3)
    {
        NSInteger season = [[filename substringWithRange:[seMatch rangeAtIndex:1]] integerValue];
        NSInteger episode = [[filename substringWithRange:[seMatch rangeAtIndex:2]] integerValue];
        return @[ @(season), @(episode) ];
    }

    // Try 1x05 pattern
    NSRegularExpression* altSeasonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(\\d{1,2})x(\\d{1,2})\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    NSTextCheckingResult* altMatch = [altSeasonRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (altMatch && altMatch.numberOfRanges >= 3)
    {
        NSInteger season = [[filename substringWithRange:[altMatch rangeAtIndex:1]] integerValue];
        NSInteger episode = [[filename substringWithRange:[altMatch rangeAtIndex:2]] integerValue];
        return @[ @(season), @(episode) ];
    }

    return nil; // No season/episode pattern found
}

@end

@implementation NSString (Private)

+ (NSString*)stringForSpeed:(CGFloat)speed kb:(NSString*)kb mb:(NSString*)mb gb:(NSString*)gb
{
    if (speed < 999.95) // 0.0 KB/s to 999.9 KB/s
    {
        return [NSString localizedStringWithFormat:@"%.1f %@", speed, kb];
    }

    speed /= 1000.0;

    if (speed < 99.995) // 1.00 MB/s to 99.99 MB/s
    {
        return [NSString localizedStringWithFormat:@"%.2f %@", speed, mb];
    }
    else if (speed < 999.95) // 100.0 MB/s to 999.9 MB/s
    {
        return [NSString localizedStringWithFormat:@"%.1f %@", speed, mb];
    }

    speed /= 1000.0;

    if (speed < 99.995) // 1.00 GB/s to 99.99 GB/s
    {
        return [NSString localizedStringWithFormat:@"%.2f %@", speed, gb];
    }
    // 100.0 GB/s and above
    return [NSString localizedStringWithFormat:@"%.1f %@", speed, gb];
}

+ (NSString*)stringForSpeedCompact:(CGFloat)speed kb:(NSString*)kb mb:(NSString*)mb gb:(NSString*)gb
{
    if (speed < 99.95) // 0.0 KB/s to 99.9 KB/s
    {
        return [NSString localizedStringWithFormat:@"%.1f %@", speed, kb];
    }
    if (speed < 999.5) // 100 KB/s to 999 KB/s
    {
        return [NSString localizedStringWithFormat:@"%.0f %@", speed, kb];
    }

    speed /= 1000.0;

    if (speed < 9.995) // 1.00 MB/s to 9.99 MB/s
    {
        return [NSString localizedStringWithFormat:@"%.2f %@", speed, mb];
    }
    if (speed < 99.95) // 10.0 MB/s to 99.9 MB/s
    {
        return [NSString localizedStringWithFormat:@"%.1f %@", speed, mb];
    }
    if (speed < 999.5) // 100 MB/s to 999 MB/s
    {
        return [NSString localizedStringWithFormat:@"%.0f %@", speed, mb];
    }

    speed /= 1000.0;

    if (speed < 9.995) // 1.00 GB/s to 9.99 GB/s
    {
        return [NSString localizedStringWithFormat:@"%.2f %@", speed, gb];
    }
    if (speed < 99.95) // 10.0 GB/s to 99.9 GB/s
    {
        return [NSString localizedStringWithFormat:@"%.1f %@", speed, gb];
    }
    // 100 GB/s and above
    return [NSString localizedStringWithFormat:@"%.0f %@", speed, gb];
}

@end
