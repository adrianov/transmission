// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>
#include <libtransmission/utils.h>

#import "NSStringAdditions.h"
#import "NSDataAdditions.h"
#import "NSString+HumanTitle.h"

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

- (NSString*)tr_stringLimitedToGraphemeClusters:(NSUInteger)max appendEllipsis:(BOOL)appendEllipsis
{
    if (max == 0 || self.length == 0)
    {
        return self;
    }

    __block NSUInteger n = 0;
    __block NSUInteger end = 0;
    [self enumerateSubstringsInRange:NSMakeRange(0, self.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString* substring, NSRange substringRange, NSRange enclosingRange, BOOL* stop) {
                              (void)substring;
                              (void)enclosingRange;
                              if (n >= max)
                              {
                                  *stop = YES;
                                  return;
                              }
                              n++;
                              end = NSMaxRange(substringRange);
                          }];

    if (end >= self.length)
    {
        return self;
    }

    NSString* out = [self substringToIndex:end];
    return appendEllipsis ? out.stringByAppendingEllipsis : out;
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
    return [self tr_formatHumanTitle];
}

- (NSString*)humanReadableFileName
{
    return [self tr_formatHumanFileName];
}

- (NSString*)humanReadableEpisodeName
{
    return [self tr_formatHumanEpisodeName];
}

- (NSString*)humanReadableEpisodeTitle
{
    return [self humanReadableEpisodeTitleWithTorrentName:nil];
}

- (NSString*)humanReadableEpisodeTitleWithTorrentName:(NSString*)torrentName
{
    return [self tr_formatHumanEpisodeTitleWithTorrentName:torrentName];
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

- (NSURL*)fileURLForOpening
{
    if (self.length == 0)
        return [NSURL fileURLWithPath:@"/"];
    NSMutableCharacterSet* allowed = [NSCharacterSet.URLPathAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@";"];
    NSString* encoded = [self stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    if (!encoded)
        return [NSURL fileURLWithPath:self];
    return [NSURL URLWithString:[@"file://" stringByAppendingString:encoded]];
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
