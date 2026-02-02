// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>
#include <gtest/gtest.h>

#import "IINAWatchHelper.h"

// Tests that IINA watch_later search uses MD5 of full normalized path (same as IINA/mpv).
class IINAWatchHelperTest : public ::testing::Test
{
};

TEST_F(IINAWatchHelperTest, watchLaterBasenameNilReturnsNil)
{
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:nil resolveSymlinks:NO];
    EXPECT_EQ(result, nil);
}

TEST_F(IINAWatchHelperTest, watchLaterBasenameEmptyReturnsNil)
{
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:@"" resolveSymlinks:NO];
    EXPECT_EQ(result, nil);
}

TEST_F(IINAWatchHelperTest, watchLaterBasenameFullPathProducesUppercaseMD5Hex)
{
    NSString* path = @"/tmp/video.mkv";
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:path resolveSymlinks:NO];
    ASSERT_NE(result, nil);
    EXPECT_EQ(result.length, 32u) << "watch_later filename must be 32-char MD5 hex";
    EXPECT_TRUE([result isEqualToString:@"2A9F23BA8B90EB3523245E86AD266928"])
        << "MD5(UTF-8 full path) must match IINA watch_later lookup; got " << result.UTF8String;
    for (NSUInteger i = 0; i < result.length; i++)
        EXPECT_TRUE([@"0123456789ABCDEF" rangeOfString:[result substringWithRange:NSMakeRange(i, 1)]].location != NSNotFound)
            << "must be uppercase hex";
}

TEST_F(IINAWatchHelperTest, watchLaterBasenameRootPath)
{
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:@"/" resolveSymlinks:NO];
    ASSERT_NE(result, nil);
    EXPECT_EQ(result.length, 32u);
    EXPECT_TRUE([result isEqualToString:@"6666CD76F96956469E7BE39D750CC7D9"]);
}

TEST_F(IINAWatchHelperTest, watchLaterBasenameUserPath)
{
    NSString* path = @"/Users/test/Downloads/sample.mkv";
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:path resolveSymlinks:NO];
    ASSERT_NE(result, nil);
    EXPECT_EQ(result.length, 32u);
    EXPECT_TRUE([result isEqualToString:@"B48321D1A81D3A1E0FFDCF5153678EBF"]);
}

TEST_F(IINAWatchHelperTest, watchLaterBasenameDeterministic)
{
    NSString* path = @"/tmp/video.mkv";
    NSString* a = [IINAWatchHelper watchLaterBasenameForPath:path resolveSymlinks:NO];
    NSString* b = [IINAWatchHelper watchLaterBasenameForPath:path resolveSymlinks:NO];
    EXPECT_TRUE([a isEqualToString:b]);
}

TEST_F(IINAWatchHelperTest, watchLaterBasenameStandardizedPath)
{
    NSString* withDot = @"/tmp/./video.mkv";
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:withDot resolveSymlinks:NO];
    EXPECT_TRUE([result isEqualToString:@"2A9F23BA8B90EB3523245E86AD266928"]) << "Standardized path must produce same MD5 as canonical path";
}

// IINA watch_later uses MD5(full path) as filename (uppercase hex). Verify with real path from user check:
// echo -n "/Users/.../Ponies.2026.../Ponies.2026.S01E06....mkv" | md5 → 1123b702cc...; ls watch_later | grep 1123 → 1123B702CC...
TEST_F(IINAWatchHelperTest, watchLaterBasenameMatchesIINALookup)
{
    NSString* path = @"/Users/adrianov/Downloads/Ponies.2026.S01.1080p.WEB-DL.H264/Ponies.2026.S01E06.1080p.WEB-DL.H264.mkv";
    NSString* result = [IINAWatchHelper watchLaterBasenameForPath:path resolveSymlinks:NO];
    ASSERT_NE(result, nil);
    EXPECT_EQ(result.length, 32u);
    EXPECT_TRUE([result isEqualToString:@"1123B702CC227C67D0AC267C94F27A70"])
        << "MD5 of full path must match IINA watch_later filename (uppercase)";
}
