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
