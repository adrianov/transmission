// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (NSStringAdditions)

@property(nonatomic, class, readonly) NSString* ellipsis;
@property(nonatomic, readonly, copy) NSString* stringByAppendingEllipsis;

+ (NSString*)stringForFileSize:(uint64_t)size;
+ (NSString*)stringForFilePartialSize:(uint64_t)partialSize fullSize:(uint64_t)fullSize;
+ (NSString*)stringForFileSizeOneDecimal:(uint64_t)size;

// 4 significant digits
+ (NSString*)stringForSpeed:(CGFloat)speed;
// 4 significant digits
+ (NSString*)stringForSpeedAbbrev:(CGFloat)speed;
// 3 significant digits
+ (NSString*)stringForSpeedAbbrevCompact:(CGFloat)speed;
+ (NSString*)stringForRatio:(CGFloat)ratio;

+ (NSString*)percentString:(CGFloat)progress longDecimals:(BOOL)longDecimals;

// simple compare method for strings with numbers (works for IP addresses)
- (NSComparisonResult)compareNumeric:(NSString*)string;

// like componentsSeparatedByCharactersInSet:, but excludes blank values
- (NSArray<NSString*>*)nonEmptyComponentsSeparatedByCharactersInSet:(NSCharacterSet*)separators;

+ (NSString*)convertedStringFromCString:(char const*)bytes;

/**
 * Converts a technical torrent name to a human-friendly title.
 *
 * Examples:
 *   Ponies.S01.1080p.PCOK.WEB-DL.H264 -> Ponies - Season 1 - 1080p
 *   Major.Grom.S01.2025.WEB-DL.HEVC.2160p -> Major Grom - Season 1 - 2160p
 *   Sting - Live At The Olympia Paris.2017.BDRip1080p -> Sting - Live At The Olympia Paris - 2017 - 1080p
 *   2ChicksSameTime.25.04.14.Bonnie.Rotten.2160p.mp4 -> 2ChickSameTime - 25.04.14 - Bonnie Rotten - 2160p
 */
@property(nonatomic, readonly, copy) NSString* humanReadableTitle;

/**
 * Converts a filename or folder name to a lightweight human-readable display name.
 *
 * This intentionally does not extract years/dates or strip technical tags.
 * It only replaces separator-heavy names ('.', '-', '_') with spaces.
 */
@property(nonatomic, readonly, copy) NSString* humanReadableFileName;

/**
 * Converts a filename to a human-readable episode name.
 * When SxxExx or 1x05 is present, returns both season and episode (e.g. S1 E5).
 *
 * Examples:
 *   Show.S01E05.720p.mkv -> S1 E5
 *   Show.S1.E12.HDTV.mp4 -> S1 E12
 *   Show.1x05.720p.mkv -> S1 E5
 *   Show.E05.standalone.mkv -> E5
 *
 * Returns nil if no episode pattern found.
 */
@property(nonatomic, readonly, copy, nullable) NSString* humanReadableEpisodeName;

/**
 * Converts a filename to a human-readable episode title.
 * When SxxExx or 1x05 is present, displays both season and episode; title after the marker is shown only then (e.g. S1 E1 - The Beginning).
 * Standalone E05 shows as E5 only, no title.
 *
 * Examples:
 *   Ponies.S01E01.The.Beginning.1080p -> S1 E1 - The Beginning
 *   Ponies.S01E01.1080p -> S1 E1
 *   Show.E05.standalone.mkv -> E5
 *
 * Returns nil if no episode pattern found.
 */
@property(nonatomic, readonly, copy, nullable) NSString* humanReadableEpisodeTitle;

/**
 * Converts a filename to a human-readable episode title, optionally stripping the torrent name if redundant.
 */
- (nullable NSString*)humanReadableEpisodeTitleWithTorrentName:(nullable NSString*)torrentName;

/**
 * Extracts season and episode numbers from filename.
 *
 * Returns @[@(season), @(episode)] or nil if no pattern found.
 */
@property(nonatomic, readonly, copy, nullable) NSArray<NSNumber*>* episodeNumbers;

/// File URL from path safe for opening/revealing (percent-encodes ';' etc. so system/open apps do not misinterpret).
- (NSURL*)fileURLForOpening;

@end

__attribute__((annotate("returns_localized_nsstring"))) static inline NSString* LocalizationNotNeeded(NSString* s)
{
    return s;
}

NS_ASSUME_NONNULL_END
