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

+ (NSString*)stringForFileSizeOneDecimal:(uint64_t)size
{
    if (size == 0)
    {
        return @"0.0 B";
    }

    NSString* unit;
    double value;
    uint64_t const KB = 1024;
    uint64_t const MB = KB * 1024;
    uint64_t const GB = MB * 1024;
    uint64_t const TB = GB * 1024;
    uint64_t const PB = TB * 1024;

    if (size < MB)
    {
        unit = @"KB";
        value = static_cast<double>(size) / KB;
    }
    else if (size < GB)
    {
        unit = @"MB";
        value = static_cast<double>(size) / MB;
    }
    else if (size < TB)
    {
        unit = @"GB";
        value = static_cast<double>(size) / GB;
    }
    else if (size < PB)
    {
        unit = @"TB";
        value = static_cast<double>(size) / TB;
    }
    else
    {
        unit = @"PB";
        value = static_cast<double>(size) / PB;
    }

    return [NSString stringWithFormat:@"%.1f %@", value, unit];
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

    // Always replace underscores with spaces and collapse multiple whitespaces
    title = [title stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    
    // Remove pipe characters and lowercase 'l' as separators
    title = [title stringByReplacingOccurrencesOfString:@"|" withString:@" "];
    NSRegularExpression* lSeparatorRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+l\\s+" options:0 error:nil];
    title = [lSeparatorRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];

    // Ensure space after ','
    title = [title stringByReplacingOccurrencesOfString:@"," withString:@", "];
    
    NSRegularExpression* multiSpaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    title = [multiSpaceRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    // Ensure no space after '(' and no space before ')'
    NSRegularExpression* spaceAfterParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(\\s+" options:0 error:nil];
    title = [spaceAfterParenRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@"("];
    NSRegularExpression* spaceBeforeParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+\\)" options:0 error:nil];
    title = [spaceBeforeParenRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@")"];

    // Shortcut: if title already looks clean, return it (after initial cleanup)
    // Note: '.' is NOT in the clean regex, so any title with '.' will go through full processing.
    // Also check for technical patterns (resolution, season, year, tech tags) - if found, process the title
    NSRegularExpression* cleanTitleRegex = [NSRegularExpression regularExpressionWithPattern:@"^[\\p{L}\\p{N}\\s,\\[\\]\\(\\)\\{\\}\\-:;]+$"
                                                                                     options:0
                                                                                       error:nil];
    BOOL const looksClean = [cleanTitleRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)] != nil;
    
    if (looksClean)
    {
        // Check for technical patterns that need processing
        NSRegularExpression* techPatternRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:2160p|1080p|720p|480p|8K|4K|UHD|S\\d{1,2}|(?:19|20)\\d{2}|DVD|BD|WEB|Rip|HEVC|H264|H265|x264|x265|AAC|AC3|DTS|FLAC|MP3|Jaskier|MVO|ExKinoRay|RuTracker)\\b"
                                                                                          options:NSRegularExpressionCaseInsensitive
                                                                                            error:nil];
        BOOL const hasTechPatterns = [techPatternRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)] != nil;
        
        if (!hasTechPatterns)
        {
            // Final cleanup: ensure no space after '(' and no space before ')'
            NSRegularExpression* finalSpaceAfterParen = [NSRegularExpression regularExpressionWithPattern:@"\\(\\s+" options:0 error:nil];
            title = [finalSpaceAfterParen stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@"("];
            NSRegularExpression* finalSpaceBeforeParen = [NSRegularExpression regularExpressionWithPattern:@"\\s+\\)" options:0 error:nil];
            title = [finalSpaceBeforeParen stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@")"];
            return title;
        }
    }

    // Remove file extension (any 2-5 character alphanumeric extension)
    NSRegularExpression* extRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.[a-z0-9]{2,5}$"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    if (extRegex != nil)
    {
        title = [extRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    }

    // Extract format tags and year from parentheses metadata (e.g., (2016,LP) -> extract LP as format, (2025, Digital Release) -> extract 2025 as year)
    // This must be done before normalizing brackets to preserve the metadata structure
    // Only process parentheses that contain commas (metadata format), not simple year parentheses like (1975)
    // Create regex objects once for reuse (performance optimization)
    static NSRegularExpression* parenMetadataRegex = nil;
    static NSRegularExpression* yearInMetadataRegex = nil;
    static NSRegularExpression* formatTagRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        parenMetadataRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(([^)]+)\\)" options:0 error:nil];
        yearInMetadataRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19\\d{2}|20\\d{2})\\b" options:0 error:nil];
        formatTagRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(LP|CD|EP|DVD|BD|DVD5|DVD9|BD25|BD50|BD66|BD100)\\b"
                                                                     options:NSRegularExpressionCaseInsensitive
                                                                       error:nil];
    });
    
    NSArray<NSTextCheckingResult*>* parenMatches = [parenMetadataRegex matchesInString:title options:0 range:NSMakeRange(0, title.length)];
    NSString* extractedFormat = nil;
    NSString* extractedYearFromMetadata = nil;
    NSMutableArray<NSValue*>* rangesToRemove = [NSMutableArray array];
    
    for (NSTextCheckingResult* match in parenMatches)
    {
        if (match.numberOfRanges > 1)
        {
            NSString* content = [title substringWithRange:[match rangeAtIndex:1]];
            // Check if this looks like metadata (contains comma-separated values like "2016,LP" or "2025, Digital Release")
            // Skip simple year-only parentheses like "(1975)" - those are handled by year extraction
            if ([content containsString:@","])
            {
                NSArray<NSString*>* parts = [content componentsSeparatedByString:@","];
                for (NSString* part in parts)
                {
                    NSString* trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    // First, check if this part is a year (4-digit year 1900-2099)
                    if (!extractedYearFromMetadata)
                    {
                        NSTextCheckingResult* yearMatch = [yearInMetadataRegex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
                        if (yearMatch)
                        {
                            extractedYearFromMetadata = [trimmed substringWithRange:yearMatch.range];
                        }
                    }
                    // Check for format tags: LP, CD, DVD, BD, etc.
                    if (!extractedFormat)
                    {
                        NSTextCheckingResult* formatMatch = [formatTagRegex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
                        if (formatMatch)
                        {
                            NSString* matched = [trimmed substringWithRange:formatMatch.range];
                            // Normalize to uppercase for disc formats, lowercase for audio formats
                            if ([matched.uppercaseString isEqualToString:@"LP"] || [matched.uppercaseString isEqualToString:@"CD"] || [matched.uppercaseString isEqualToString:@"EP"])
                            {
                                extractedFormat = matched.lowercaseString;
                            }
                            else
                            {
                                extractedFormat = matched.uppercaseString;
                            }
                        }
                    }
                    // Early exit if we found both
                    if (extractedFormat && extractedYearFromMetadata)
                    {
                        break;
                    }
                }
                // Mark this parentheses metadata group for removal
                [rangesToRemove addObject:[NSValue valueWithRange:match.range]];
            }
        }
    }
    
    // Remove parentheses metadata groups (in reverse order to preserve indices)
    for (NSValue* rangeValue in [rangesToRemove reverseObjectEnumerator])
    {
        NSRange range = [rangeValue rangeValue];
        title = [title stringByReplacingCharactersInRange:range withString:@" "];
    }
    
    // Clean up any orphaned commas or parentheses artifacts left after metadata removal
    // Remove patterns like ", )" that might be left after removing parentheses metadata
    static NSRegularExpression* orphanCommaParenRegex = nil;
    static NSRegularExpression* orphanFormatParenRegex = nil;
    static dispatch_once_t cleanupOnceToken;
    dispatch_once(&cleanupOnceToken, ^{
        orphanCommaParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s*,\\s*\\)" options:0 error:nil];
        orphanFormatParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s*,\\s*(LP|CD|EP)\\s*\\)" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    title = [orphanCommaParenRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    title = [orphanFormatParenRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    
    // Normalize bracketed metadata early to simplify parsing
    title = [title stringByReplacingOccurrencesOfString:@"[" withString:@" "];
    title = [title stringByReplacingOccurrencesOfString:@"]" withString:@" "];
    NSRegularExpression* bracketSpaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s{2,}" options:0 error:nil];
    title = [bracketSpaceRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    NSRegularExpression* doubleDashRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s-\\s-\\s" options:0 error:nil];
    title = [doubleDashRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" - "];

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
    NSString* resolution = nil;
    if (resMatch && resMatch.numberOfRanges > 1)
    {
        resolution = [title substringWithRange:[resMatch rangeAtIndex:1]];
    }

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

    // Check for DVD/BD format tags (shown as #DVD5, #BD50, etc.) - uppercase
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

    // Legacy codecs (shown as #xvid, #divx) - lowercase
    if (!resolution)
    {
        NSRegularExpression* codecRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(XviD|DivX)\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
        NSTextCheckingResult* codecMatch = [codecRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        if (codecMatch)
        {
            resolution = [title substringWithRange:codecMatch.range].lowercaseString;
        }
    }

    // Audio format tags (shown as #mp3, #flac, etc.) - keep lowercase
    // Also match Cyrillic МР3 (М=M, Р=P in Cyrillic)
    if (!resolution)
    {
        NSRegularExpression* audioFormatRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A|LP|CD|EP)\\b"
                                                                                          options:NSRegularExpressionCaseInsensitive
                                                                                            error:nil];
        NSTextCheckingResult* audioFormatMatch = [audioFormatRegex firstMatchInString:title options:0
                                                                                range:NSMakeRange(0, title.length)];
        if (audioFormatMatch)
        {
            NSString* matched = [title substringWithRange:audioFormatMatch.range];
            // LP, CD, EP should be lowercase, others too
            resolution = matched.lowercaseString;
        }
        else
        {
            // Check for Cyrillic variants
            NSRegularExpression* cyrillicMp3Regex = [NSRegularExpression regularExpressionWithPattern:@"\\(?(МР3|МРЗ)\\)?"
                                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                                error:nil];
            NSTextCheckingResult* cyrillicMatch = [cyrillicMp3Regex firstMatchInString:title options:0
                                                                                 range:NSMakeRange(0, title.length)];
            if (cyrillicMatch)
            {
                resolution = @"mp3";
            }
        }
    }
    
    // Use format extracted from parentheses metadata if no resolution found yet
    if (!resolution && extractedFormat)
    {
        resolution = extractedFormat;
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
    NSRegularExpression* fullDateRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{4})[\\])]?"
                                                                                   options:0
                                                                                     error:nil];
    NSTextCheckingResult* fullDateMatch = [fullDateRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];

    // Extract date pattern YY.MM.DD (e.g., 25.04.14)
    NSRegularExpression* shortDateRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\[(]?(\\d{2}\\.\\d{2}\\.\\d{2})[\\])]?"
                                                                                    options:0
                                                                                      error:nil];
    NSTextCheckingResult* shortDateMatch = [shortDateRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];

    // Use full date if found, otherwise short date
    // Extract just the date part (group 1), not the parentheses
    NSTextCheckingResult* dateMatch = fullDateMatch ?: shortDateMatch;
    NSString* date = nil;
    if (dateMatch && dateMatch.numberOfRanges > 1)
    {
        date = [title substringWithRange:[dateMatch rangeAtIndex:1]];
    }

    // Year interval pattern (e.g., "2000 - 2003" or "2000-2003")
    NSRegularExpression* yearIntervalRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b((?:19|20)\\d{2})\\s*-\\s*((?:19|20)\\d{2})\\b"
                                                                                       options:0
                                                                                         error:nil];
    NSTextCheckingResult* yearIntervalMatch = [yearIntervalRegex firstMatchInString:title options:0
                                                                              range:NSMakeRange(0, title.length)];
    NSString* yearInterval = nil;
    if (yearIntervalMatch && yearIntervalMatch.numberOfRanges > 2)
    {
        NSString* startYear = [title substringWithRange:[yearIntervalMatch rangeAtIndex:1]];
        NSString* endYear = [title substringWithRange:[yearIntervalMatch rangeAtIndex:2]];
        yearInterval = [NSString stringWithFormat:@"%@-%@", startYear, endYear];
    }

    // Extract year (1900-2099) - but not if it's part of a date or interval
    // Also use year extracted from parentheses metadata if no other year found
    NSString* year = nil;
    if (!fullDateMatch && !yearInterval)
    {
        NSRegularExpression* yearRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(19\\d{2}|20\\d{2})\\b" options:0
                                                                                     error:nil];
        NSTextCheckingResult* yearMatch = [yearRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        year = yearMatch ? [title substringWithRange:yearMatch.range] : nil;
        // If no year found in title, use year extracted from parentheses metadata
        if (!year && extractedYearFromMetadata)
        {
            year = extractedYearFromMetadata;
        }
    }

    // Remove any [Source]-?Rip variants (e.g., WEB-Rip, WEBRip, BD-Rip, BDRip)
    NSRegularExpression* ripRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b[a-z0-9]+-?rip\\b"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    if (ripRegex != nil)
    {
        title = [ripRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    }

    // Remove any [Source]HD variants (e.g., EniaHD, playHD)
    NSRegularExpression* hdRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b[a-z0-9]+HD\\b"
                                                                             options:NSRegularExpressionCaseInsensitive
                                                                               error:nil];
    if (hdRegex != nil)
    {
        title = [hdRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    }

    // Remove any [Source]-?SbR variants (e.g., SbR, -SbR)
    NSRegularExpression* sbrRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b[a-z0-9]*-?SbR\\b"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    if (sbrRegex != nil)
    {
        title = [sbrRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
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
        @"WEB-DLRip",
        @"DLRip",
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
        @"HDCLUB",
        @"Jaskier",
        @"MVO",
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

    // Remove tech tags
    for (NSString* tag in techTags)
    {
        NSString* pattern = [NSString stringWithFormat:@"\\b%@\\b", tag];
        NSRegularExpression* tagRegex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        title = [tagRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    }

    // Remove resolution, season markers, year, date from title (and preceding dot, #, or surrounding parentheses)
    NSRegularExpression* resRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?#?\\(?\\b(2160p|1080p|720p|480p)\\b\\)?"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    title = [resRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    NSRegularExpression* uhdRemoveRegex = [NSRegularExpression
        regularExpressionWithPattern:@"\\.?#?\\(?(\\b(?:8K|4K|UHD|DVD5|DVD9|DVD|BD25|BD50|BD66|BD100|XviD|DivX|MP3|FLAC|OGG|AAC|WAV|APE|ALAC|WMA|OPUS|M4A|LP|CD|EP)\\b)\\)?"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    title = [uhdRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    // Remove Cyrillic audio format variants
    NSRegularExpression* cyrillicMp3RemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(?(МР3|МРЗ)\\)?"
                                                                                            options:NSRegularExpressionCaseInsensitive
                                                                                              error:nil];
    title = [cyrillicMp3RemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                        withTemplate:@""];

    NSRegularExpression* seasonRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?S\\d{1,2}(E\\d+)?\\b"
                                                                                       options:NSRegularExpressionCaseInsensitive
                                                                                         error:nil];
    title = [seasonRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    // Remove year interval (and preceding dot or surrounding parentheses)
    if (yearInterval)
    {
        NSRegularExpression* yearIntervalRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?\\(?(?:19|20)\\d{2}\\s*-\\s*(?:19|20)\\d{2}\\)?"
                                                                                                 options:0
                                                                                                   error:nil];
        title = [yearIntervalRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                             withTemplate:@""];
    }
    if (year)
    {
        // Remove year and surrounding parentheses or preceding dot
        NSRegularExpression* yearRemoveRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.?\\(?(19\\d{2}|20\\d{2})\\)?"
                                                                                         options:0
                                                                                           error:nil];
        title = [yearRemoveRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                     withTemplate:@""];
    }
    // Remove both date formats
    title = [fullDateRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    title = [shortDateRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

    // Replace dots with spaces if more than 2 words are glued with dots (e.g., Word.Word.Word)
    // or if the title uses dots as separators (no spaces at all)
    NSRegularExpression* gluedDotsRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{N}]+\\.[\\p{L}\\p{N}]+\\.[\\p{L}\\p{N}]+" options:0 error:nil];
    BOOL const hasGluedDots = [gluedDotsRegex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)] != nil;
    BOOL const hasNoSpaces = ![title containsString:@" "];
    if (hasGluedDots || (hasNoSpaces && [title containsString:@"."]))
    {
        title = [title stringByReplacingOccurrencesOfString:@"." withString:@" "];
    }

    // Normalize separators: only add spaces around hyphens that already have space on at least one side.
    // Preserve hyphenated words (e.g., "Butt-Head", "Blu-Ray") - no spaces around the hyphen.
    NSString* dashPlaceholder = @"\u0000";
    NSRegularExpression* dashGroupRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:\\s+-\\s*|\\s*-\\s+)+"
                                                                                     options:0
                                                                                       error:nil];
    title = [dashGroupRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length)
                                                withTemplate:dashPlaceholder];
    NSRegularExpression* spacedDashRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|\\s)-(?:\\s|$)" options:0
                                                                                       error:nil];
    title = [spacedDashRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    title = [title stringByReplacingOccurrencesOfString:dashPlaceholder withString:@" - "];

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

    // Remove empty parentheses (artifacts from tag removal)
    NSRegularExpression* emptyParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(\\s*\\)" options:0 error:nil];
    title = [emptyParenRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];

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
    if (yearInterval)
    {
        [result appendFormat:@" (%@)", yearInterval];
    }
    else if (year && !date)
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

    // Final cleanup: ensure no space after '(' and no space before ')'
    NSString* finalResult = result;
    NSRegularExpression* finalSpaceAfterParen = [NSRegularExpression regularExpressionWithPattern:@"\\(\\s+" options:0 error:nil];
    finalResult = [finalSpaceAfterParen stringByReplacingMatchesInString:finalResult options:0 range:NSMakeRange(0, finalResult.length) withTemplate:@"("];
    NSRegularExpression* finalSpaceBeforeParen = [NSRegularExpression regularExpressionWithPattern:@"\\s+\\)" options:0 error:nil];
    finalResult = [finalSpaceBeforeParen stringByReplacingMatchesInString:finalResult options:0 range:NSMakeRange(0, finalResult.length) withTemplate:@")"];

    return finalResult.length > 0 ? finalResult : self;
}

- (NSString*)humanReadableFileName
{
    if (self.length == 0)
    {
        return @"Unknown";
    }

    NSString* name = self.lastPathComponent;
    if (name.length == 0)
    {
        return @"Unknown";
    }

    // Always replace underscores with spaces and collapse multiple whitespaces
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    
    // Remove pipe characters and lowercase 'l' as separators
    name = [name stringByReplacingOccurrencesOfString:@"|" withString:@" "];
    NSRegularExpression* lSeparatorRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+l\\s+" options:0 error:nil];
    name = [lSeparatorRegex stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@" "];

    // Ensure space after ','
    name = [name stringByReplacingOccurrencesOfString:@"," withString:@", "];
    
    NSRegularExpression* multiSpaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    name = [multiSpaceRegex stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@" "];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    // Ensure no space after '(' and no space before ')'
    NSRegularExpression* spaceAfterParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\(\\s+" options:0 error:nil];
    name = [spaceAfterParenRegex stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@"("];
    NSRegularExpression* spaceBeforeParenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+\\)" options:0 error:nil];
    name = [spaceBeforeParenRegex stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@")"];

    NSUInteger whitespaceCount = 0;
    NSUInteger dotCount = 0;
    NSUInteger hyphenCount = 0;
    NSUInteger underscoreCount = 0;

    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i = 0; i < name.length; ++i)
    {
        unichar const c = [name characterAtIndex:i];
        if ([whitespace characterIsMember:c])
        {
            ++whitespaceCount;
        }
        else if (c == '.')
        {
            ++dotCount;
        }
        else if (c == '-')
        {
            ++hyphenCount;
        }
        else if (c == '_')
        {
            ++underscoreCount;
        }
    }

    NSUInteger const separatorCount = dotCount + hyphenCount + underscoreCount;
    BOOL const noSpaces = whitespaceCount == 0;
    BOOL const shouldReplaceSeparators = (separatorCount >= 3 && separatorCount > whitespaceCount) ||
        (noSpaces && (underscoreCount > 0 || dotCount >= 2 || hyphenCount >= 2));

    if (!shouldReplaceSeparators)
    {
        return name;
    }

    NSMutableString* out = [NSMutableString stringWithCapacity:name.length];
    NSCharacterSet* digits = NSCharacterSet.decimalDigitCharacterSet;

    for (NSUInteger i = 0; i < name.length; ++i)
    {
        unichar const c = [name characterAtIndex:i];
        unichar const prev = i > 0 ? [name characterAtIndex:i - 1] : 0;
        unichar const next = i + 1 < name.length ? [name characterAtIndex:i + 1] : 0;
        BOOL const betweenDigits = i > 0 && i + 1 < name.length && [digits characterIsMember:prev] && [digits characterIsMember:next];

        if (c == '_')
        {
            [out appendString:@" "];
        }
        else if (c == '.')
        {
            [out appendString:betweenDigits ? @"." : @" "];
        }
        else if (c == '-')
        {
            BOOL const spacedDash = prev == ' ' && next == ' ';
            BOOL const isHyphenatedWord = i > 0 && i + 1 < name.length &&
                                          [[NSCharacterSet letterCharacterSet] characterIsMember:prev] &&
                                          [[NSCharacterSet letterCharacterSet] characterIsMember:next];
            if (betweenDigits || spacedDash || isHyphenatedWord)
            {
                [out appendFormat:@"%C", c];
            }
            else
            {
                [out appendString:@" "];
            }
        }
        else
        {
            [out appendFormat:@"%C", c];
        }
    }

    NSArray<NSString*>* parts = [out nonEmptyComponentsSeparatedByCharactersInSet:whitespace];
    NSString* normalized = [parts componentsJoinedByString:@" "];
    return normalized.length > 0 ? normalized : name;
}

- (NSString*)humanReadableEpisodeName
{
    NSString* filename = self.lastPathComponent;

    // Try S01E05 or S1E5 pattern (most common for TV shows)
    NSRegularExpression* seasonEpisodeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bS(\\d{1,2})[.\\s]?E(\\d{1,3})\\b"
                                                                                        options:NSRegularExpressionCaseInsensitive
                                                                                          error:nil];
    NSTextCheckingResult* seMatch = [seasonEpisodeRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (seMatch && seMatch.numberOfRanges >= 3)
    {
        NSInteger episode = [[filename substringWithRange:[seMatch rangeAtIndex:2]] integerValue];
        return [NSString stringWithFormat:@"E%ld", (long)episode];
    }

    // Try E05 or E12 pattern (standalone episode)
    NSRegularExpression* standaloneEpisodeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bE(\\d{1,3})\\b"
                                                                                            options:NSRegularExpressionCaseInsensitive
                                                                                              error:nil];
    NSTextCheckingResult* standaloneMatch = [standaloneEpisodeRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (standaloneMatch && standaloneMatch.numberOfRanges >= 2)
    {
        NSInteger episode = [[filename substringWithRange:[standaloneMatch rangeAtIndex:1]] integerValue];
        return [NSString stringWithFormat:@"E%ld", (long)episode];
    }

    // Try 1x05 pattern (alternative TV format)
    NSRegularExpression* altSeasonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(\\d{1,2})x(\\d{1,3})\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    NSTextCheckingResult* altMatch = [altSeasonRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (altMatch && altMatch.numberOfRanges >= 3)
    {
        NSInteger episode = [[filename substringWithRange:[altMatch rangeAtIndex:2]] integerValue];
        return [NSString stringWithFormat:@"E%ld", (long)episode];
    }

    // No episode pattern found - return nil to use humanized filename instead
    return nil;
}

- (NSString*)humanReadableEpisodeTitle
{
    return [self humanReadableEpisodeTitleWithTorrentName:nil];
}

- (NSString*)humanReadableEpisodeTitleWithTorrentName:(NSString*)torrentName
{
    NSString* filename = self.lastPathComponent;

    // Match SxxExx or Exx pattern
    NSRegularExpression* episodeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:S?\\d{1,2})?E(\\d{1,3})\\b"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
    if (episodeRegex == nil)
    {
        return nil;
    }
    NSTextCheckingResult* episodeMatch = [episodeRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (!episodeMatch)
    {
        return nil;
    }

    NSInteger episodeNum = [[filename substringWithRange:[episodeMatch rangeAtIndex:1]] integerValue];
    NSString* episodePrefix = [NSString stringWithFormat:@"E%ld", (long)episodeNum];

    // Try to extract title after the episode marker
    // Remove everything before and including the episode marker
    NSString* remaining = [filename substringFromIndex:episodeMatch.range.location + episodeMatch.range.length];

    // If there's a dot or hyphen immediately after, skip it
    NSRegularExpression* separatorRegex = [NSRegularExpression regularExpressionWithPattern:@"^[.\\s]+" options:0 error:nil];
    if (separatorRegex != nil)
    {
        remaining = [separatorRegex stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@""];
    }

    if (remaining.length == 0)
    {
        return episodePrefix;
    }

    // Strip technical tags from the original string BEFORE processing (so patterns with dots like H.264 work correctly)
    NSArray* tagsToStrip = @[
        @"1080p", @"720p", @"2160p", @"480p", @"8K", @"4K", @"UHD",
        @"WEB-DL", @"WEBDL", @"WEBRip", @"BDRip", @"BluRay", @"HDRip", @"DVDRip", @"HDTV",
        @"WEB-DLRip", @"DLRip",
        @"H264", @"H.264", @"H265", @"H.265", @"x264", @"x265", @"HEVC", @"AVC",
        @"AMZN", @"NF", @"DSNP", @"HMAX", @"PCOK", @"ATVP", @"APTV",
        @"2xRu", @"Ru", @"En", @"qqss44", @"WEB", @"DL"
    ];
    
    // Remove any [Source]-?Rip variants from episode title (before dot replacement)
    NSRegularExpression* ripRegexEpisode = [NSRegularExpression regularExpressionWithPattern:@"\\b[a-z0-9]+-?rip\\b"
                                                                                     options:NSRegularExpressionCaseInsensitive
                                                                                       error:nil];
    if (ripRegexEpisode != nil)
    {
        remaining = [ripRegexEpisode stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@" "];
    }

    // Remove any [Source]HD variants from episode title (before dot replacement)
    NSRegularExpression* hdRegexEpisode = [NSRegularExpression regularExpressionWithPattern:@"\\b[a-z0-9]+HD\\b"
                                                                                    options:NSRegularExpressionCaseInsensitive
                                                                                      error:nil];
    if (hdRegexEpisode != nil)
    {
        remaining = [hdRegexEpisode stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@" "];
    }

    // Remove any [Source]-?SbR variants from episode title (before dot replacement)
    NSRegularExpression* sbrRegexEpisode = [NSRegularExpression regularExpressionWithPattern:@"\\b[a-z0-9]*-?SbR\\b"
                                                                                     options:NSRegularExpressionCaseInsensitive
                                                                                       error:nil];
    if (sbrRegexEpisode != nil)
    {
        remaining = [sbrRegexEpisode stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@" "];
    }

    for (NSString* tag in tagsToStrip)
    {
        NSString* escapedTag = [NSRegularExpression escapedPatternForString:tag];
        NSString* pattern = [NSString stringWithFormat:@"\\b%@\\b", escapedTag];
        NSRegularExpression* tagRegex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        if (tagRegex != nil)
        {
            remaining = [tagRegex stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@" "];
        }
    }

    // Remove known video file extensions explicitly (NOT stringByDeletingPathExtension which might remove valid words like ".Party")
    NSRegularExpression* extRegex = [NSRegularExpression regularExpressionWithPattern:@"\\.(mkv|mp4|avi|mov|wmv|flv|webm|m4v|mpg|mpeg|ts|m2ts)$"
                                                                              options:NSRegularExpressionCaseInsensitive
                                                                                error:nil];
    if (extRegex != nil)
    {
        remaining = [extRegex stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@""];
    }
    
    // Clean up multiple spaces left by tag removal
    NSRegularExpression* multiSpaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    if (multiSpaceRegex != nil)
    {
        remaining = [multiSpaceRegex stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@" "];
    }
    remaining = [remaining stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    // Replace dots with spaces (they are word separators in episode titles)
    // But preserve dots between digits (e.g., "2.0" in titles)
    NSMutableString* dotCleaned = [NSMutableString stringWithCapacity:remaining.length];
    NSCharacterSet* digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSUInteger i = 0; i < remaining.length; i++)
    {
        unichar c = [remaining characterAtIndex:i];
        if (c == '.')
        {
            unichar prev = i > 0 ? [remaining characterAtIndex:i - 1] : 0;
            unichar next = i + 1 < remaining.length ? [remaining characterAtIndex:i + 1] : 0;
            BOOL betweenDigits = [digits characterIsMember:prev] && [digits characterIsMember:next];
            [dotCleaned appendString:betweenDigits ? @"." : @" "];
        }
        else
        {
            [dotCleaned appendFormat:@"%C", c];
        }
    }
    remaining = dotCleaned;
    
    // Clean up spaces again after dot replacement
    if (multiSpaceRegex != nil)
    {
        remaining = [multiSpaceRegex stringByReplacingMatchesInString:remaining options:0 range:NSMakeRange(0, remaining.length) withTemplate:@" "];
    }
    remaining = [remaining stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    // Cleanup the remaining part using humanReadableFileName logic (handles hyphens correctly)
    NSString* title = remaining.humanReadableFileName;

    // Final cleanup of spaces and separators
    // Also remove empty brackets/parentheses like [] or ()
    NSRegularExpression* emptyBracketsRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\[\\(]\\s*[\\]\\)]" options:0 error:nil];
    if (emptyBracketsRegex != nil)
    {
        title = [emptyBracketsRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
    }

    // Remove stray closing brackets or parentheses that might be left over
    title = [title stringByReplacingOccurrencesOfString:@"]" withString:@""];
    title = [title stringByReplacingOccurrencesOfString:@")" withString:@""];
    title = [title stringByReplacingOccurrencesOfString:@"|" withString:@""];
    NSRegularExpression* lSeparatorRegexEpisode = [NSRegularExpression regularExpressionWithPattern:@"\\s+l\\s+" options:0 error:nil];
    title = [lSeparatorRegexEpisode stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];

    // Ensure space after ','
    title = [title stringByReplacingOccurrencesOfString:@"," withString:@", "];

    NSRegularExpression* spaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    if (spaceRegex != nil)
    {
        title = [spaceRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@" "];
    }
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

    // Remove trailing/leading dots and spaces
    NSCharacterSet* trimSet = [NSCharacterSet characterSetWithCharactersInString:@". "];
    title = [title stringByTrimmingCharactersInSet:trimSet];

    // Final check for file extension that might have survived the stringByDeletingPathExtension
    if ([title.lowercaseString hasSuffix:@"mkv"])
    {
        title = [title substringToIndex:title.length - 3];
        title = [title stringByTrimmingCharactersInSet:trimSet];
    }

    // If the title is just a repeat of the torrent name (movie name), it's probably garbage
    if (title.length > 1)
    {
        if (torrentName)
        {
            NSString* humanTorrentName = torrentName.humanReadableTitle;
            // Strip season/year/resolution from torrent name for comparison
            NSRegularExpression* cleanupRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s*(- Season \\d+|\\(\\d{4}\\)|#\\d+p|#\\w+)" options:0 error:nil];
            if (cleanupRegex != nil)
            {
                NSString* baseTorrentName = [cleanupRegex stringByReplacingMatchesInString:humanTorrentName options:0 range:NSMakeRange(0, humanTorrentName.length) withTemplate:@""];
                
                // If title is just the series name, or the series name + year, it's redundant
                if ([title.lowercaseString isEqualToString:baseTorrentName.lowercaseString])
                {
                    return episodePrefix;
                }
                
                // Check if title is "Series Name (Year)" or "Series Name Year"
                NSRegularExpression* yearSuffixRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(?\\b(19|20)\\d{2}\\b\\)?" options:0 error:nil];
                NSString* titleWithoutYear = [yearSuffixRegex stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0, title.length) withTemplate:@""];
                if ([titleWithoutYear.lowercaseString isEqualToString:baseTorrentName.lowercaseString])
                {
                    return episodePrefix;
                }
            }
        }

        return [NSString stringWithFormat:@"%@ - %@", episodePrefix, title];
    }

    return episodePrefix;
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
