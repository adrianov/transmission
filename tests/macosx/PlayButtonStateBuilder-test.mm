// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.
//
// Tests ETA < duration visibility rule for video files. Video files are determined by extension.
// Extension set must match Torrent+MediaType.mm sVideoExtensions.

#import <Foundation/Foundation.h>
#include <gtest/gtest.h>

static NSSet<NSString*>* videoExtensions(void)
{
    static NSSet<NSString*>* set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"mkv", @"avi", @"mp4", @"mov", @"wmv", @"flv", @"webm", @"m4v",
            @"mpg", @"mpeg", @"ts", @"m2ts", @"vob", @"3gp", @"ogv"
        ]];
    });
    return set;
}

static BOOL isVideoFileExtension(NSString* ext)
{
    if (ext.length == 0)
        return NO;
    return [videoExtensions() containsObject:ext.lowercaseString];
}

TEST(PlayButtonStateBuilderTest, isVideoFileExtensionMp4)
{
    EXPECT_TRUE(isVideoFileExtension(@"mp4"));
    EXPECT_TRUE(isVideoFileExtension(@"MP4"));
}

TEST(PlayButtonStateBuilderTest, isVideoFileExtensionMkv)
{
    EXPECT_TRUE(isVideoFileExtension(@"mkv"));
}

TEST(PlayButtonStateBuilderTest, isVideoFileExtensionWebm)
{
    EXPECT_TRUE(isVideoFileExtension(@"webm"));
}

TEST(PlayButtonStateBuilderTest, isVideoFileExtensionNonVideo)
{
    EXPECT_FALSE(isVideoFileExtension(@"mp3"));
    EXPECT_FALSE(isVideoFileExtension(@"pdf"));
    EXPECT_FALSE(isVideoFileExtension(@"txt"));
}

TEST(PlayButtonStateBuilderTest, isVideoFileExtensionNil)
{
    EXPECT_FALSE(isVideoFileExtension(nil));
}

TEST(PlayButtonStateBuilderTest, isVideoFileExtensionEmpty)
{
    EXPECT_FALSE(isVideoFileExtension(@""));
}

// ETA < duration: show play button for video files when download ETA is less than media duration.
static BOOL showVideoByEtaDuration(double etaSec, double durationSec)
{
    return etaSec < durationSec;
}

TEST(PlayButtonStateBuilderTest, etaLessThanDurationShowsButton)
{
    EXPECT_TRUE(showVideoByEtaDuration(60.0, 120.0));
    EXPECT_TRUE(showVideoByEtaDuration(0.5, 1.0));
}

TEST(PlayButtonStateBuilderTest, etaGreaterThanDurationHidesButton)
{
    EXPECT_FALSE(showVideoByEtaDuration(120.0, 60.0));
    EXPECT_FALSE(showVideoByEtaDuration(1.0, 0.5));
}

TEST(PlayButtonStateBuilderTest, etaEqualsDurationHidesButton)
{
    EXPECT_FALSE(showVideoByEtaDuration(60.0, 60.0));
}

/// Mirrors disambiguateDuplicateTitles from PlayButtonStateBuilder.mm: counts duplicates per season.
static void testDisambiguateDuplicateTitles(NSMutableArray<NSMutableDictionary*>* state, NSArray<NSNumber*>* seasons)
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
        NSString* base = state[i][@"title"] ?: @"";
        state[i][@"title"] = [NSString stringWithFormat:@"Parent%@ — %@", season, base];
    }
}

TEST(PlayButtonStateBuilderTest, CrossSeasonDuplicatesNotDisambiguated)
{
    // "E1" in season 1 and "E1" in season 2 should NOT trigger disambiguation
    // because they appear under different season headers.
    NSMutableArray<NSMutableDictionary*>* state = [NSMutableArray array];
    [state addObject:[@{ @"title" : @"E1" } mutableCopy]];
    [state addObject:[@{ @"title" : @"E2" } mutableCopy]];
    [state addObject:[@{ @"title" : @"E1" } mutableCopy]];
    [state addObject:[@{ @"title" : @"E2" } mutableCopy]];
    NSArray<NSNumber*>* seasons = @[ @1, @1, @2, @2 ];

    testDisambiguateDuplicateTitles(state, seasons);

    // Titles should remain unchanged — no "—" prepended
    EXPECT_STREQ([state[0][@"title"] UTF8String], "E1");
    EXPECT_STREQ([state[1][@"title"] UTF8String], "E2");
    EXPECT_STREQ([state[2][@"title"] UTF8String], "E1");
    EXPECT_STREQ([state[3][@"title"] UTF8String], "E2");
}

TEST(PlayButtonStateBuilderTest, SameSeasonDuplicatesDisambiguated)
{
    // "E1" appearing twice in the same season SHOULD be disambiguated.
    NSMutableArray<NSMutableDictionary*>* state = [NSMutableArray array];
    [state addObject:[@{ @"title" : @"E1" } mutableCopy]];
    [state addObject:[@{ @"title" : @"E1" } mutableCopy]];
    [state addObject:[@{ @"title" : @"E2" } mutableCopy]];
    NSArray<NSNumber*>* seasons = @[ @1, @1, @1 ];

    testDisambiguateDuplicateTitles(state, seasons);

    // The two "E1" entries should be disambiguated (contain "—")
    EXPECT_TRUE([state[0][@"title"] containsString:@"—"]) << "Same-season duplicate should be disambiguated, got: " << [state[0][@"title"] UTF8String];
    EXPECT_TRUE([state[1][@"title"] containsString:@"—"]) << "Same-season duplicate should be disambiguated, got: " << [state[1][@"title"] UTF8String];
    // "E2" is unique and should stay unchanged
    EXPECT_STREQ([state[2][@"title"] UTF8String], "E2");
}
