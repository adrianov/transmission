// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <gtest/gtest.h>

#import "macosx/NSStringAdditions.h"

// Mock class to test icon logic without full TorrentTableView dependencies. Icon follows what opens: pathToOpen .cue = album.
@interface PlayButtonIconTester : NSObject
- (NSString*)symbolNameForType:(NSString*)type category:(NSString*)category path:(NSString*)path;
- (NSString*)symbolNameForType:(NSString*)type
                      category:(NSString*)category
                          path:(NSString*)path
                    pathToOpen:(NSString*)pathToOpen;
@end

@implementation PlayButtonIconTester

- (NSString*)symbolNameForType:(NSString*)type
                      category:(NSString*)category
                          path:(NSString*)path
                    pathToOpen:(NSString*)pathToOpen
{
    NSString* effectivePath = pathToOpen.length > 0 ? pathToOpen : path;
    BOOL const opensAsCue = effectivePath.length > 0 && [effectivePath.pathExtension.lowercaseString isEqualToString:@"cue"];
    NSString* symbolName = @"play";

    if ([type isEqualToString:@"document-books"] || [category isEqualToString:@"books"])
    {
        symbolName = @"book";
    }
    else if (opensAsCue || [type isEqualToString:@"album"])
    {
        symbolName = @"music.note.list";
    }
    else if ([type isEqualToString:@"track"] || [category isEqualToString:@"audio"])
    {
        symbolName = @"music.note";
    }
    else if ([type isEqualToString:@"dvd"] || [type isEqualToString:@"bluray"] || [category isEqualToString:@"video"])
    {
        symbolName = @"play";
    }
    else if ([category isEqualToString:@"software"])
    {
        symbolName = @"gearshape";
    }

    return symbolName;
}

- (NSString*)symbolNameForType:(NSString*)type category:(NSString*)category path:(NSString*)path
{
    return [self symbolNameForType:type category:category path:path pathToOpen:nil];
}

@end

class NSStringAdditionsTest : public ::testing::Test
{
};

TEST_F(NSStringAdditionsTest, HumanReadableTitle_720pResolution)
{
    // Test that 720p is recognized and displayed with # prefix
    NSString* input = @"Utopia 1 season MVO Jaskier 720p";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#720p"]) << "Should contain #720p, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"MVO"]) << "Should not contain MVO, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"Jaskier"]) << "Should not contain Jaskier, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_720pWithHashPrefix)
{
    // Test that #720p in the title is handled correctly
    NSString* input = @"Utopia. 2 season #720p";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#720p"]) << "Should contain #720p, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"# #720p"]) << "Should not have double #, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_EmptyParenthesesRemoved)
{
    // Test that empty parentheses are removed after tag removal
    NSString* input = @"Utopia. 2 season (WEB-DL l 720p l Jaskier)";
    NSString* result = input.humanReadableTitle;
    EXPECT_FALSE([result containsString:@"()"]) << "Should not contain empty parentheses, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"( )"]) << "Should not contain empty parentheses with space, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"#720p"]) << "Should contain #720p, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_1080pResolution)
{
    NSString* input = @"Ponies.S01.1080p.PCOK.WEB-DL.H264";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#1080p"]) << "Should contain #1080p, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"Season 1"]) << "Should contain Season 1, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_ResolutionInParenthesesNoUnpairedParen)
{
    // Regression: "(1080p HD).m4v" must not become "Hick HD) #1080p" (unpaired ')').
    NSString* input = @"Hick (1080p HD).m4v";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#1080p"]) << "Should contain #1080p, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"HD)"]) << "Should not contain unpaired ')', got: " << [result UTF8String];
    EXPECT_TRUE([result hasPrefix:@"Hick"]) << "Should start with Hick, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_2160pResolution)
{
    NSString* input = @"Major.Grom.Igra.protiv.pravil.S01.2025.WEB-DL.HEVC.2160p.SDR.ExKinoRay";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#2160p"]) << "Should contain #2160p, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"Season 1"]) << "Should contain Season 1, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"(2025)"]) << "Should contain year, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_4KUHDNormalized)
{
    NSString* input = @"Documentary.4K.HDR.2023";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#2160p"]) << "4K should be normalized to #2160p, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_SeasonDetection)
{
    NSString* input = @"Show.S01.1080p";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"Season 1"]) << "Should detect Season 1, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_YearExtraction)
{
    NSString* input = @"Movie.2020.1080p.BluRay.x264";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"(2020)"]) << "Should extract year, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_TechnicalTagsRemoved)
{
    NSString* input = @"Movie.2020.1080p.BluRay.x264.WEB-DL";
    NSString* result = input.humanReadableTitle;
    EXPECT_FALSE([result containsString:@"BluRay"]) << "Should remove BluRay, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"x264"]) << "Should remove x264, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"WEB-DL"]) << "Should remove WEB-DL, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_JaskierAndMVORemoved)
{
    NSString* input = @"Utopia 1 season MVO Jaskier 720p";
    NSString* result = input.humanReadableTitle;
    EXPECT_FALSE([result containsString:@"MVO"]) << "Should remove MVO, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"Jaskier"]) << "Should remove Jaskier, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"#720p"]) << "Should contain #720p, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_DVD5Format)
{
    NSString* input = @"Some.Movie.2020.DVD9.mkv";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#DVD9"]) << "Should contain #DVD9, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_BD50Format)
{
    NSString* input = @"Concert.BD50.2019";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#BD50"]) << "Should contain #BD50, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_AudioFormat)
{
    NSString* input = @"Artist - Album Name (2020) [FLAC]";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#flac"]) << "Should contain #flac, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_DateFormat)
{
    NSString* input = @"Adriana Chechik Compilation! (25.10.2021)_1080p.mp4";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"(25.10.2021)"]) << "Should contain date, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"#1080p"]) << "Should contain #1080p, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_YearInterval)
{
    NSString* input = @"Golden Disco Hits - 2000 - 2003";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"(2000-2003)"]) << "Should contain year interval, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_YearIntervalEllipsis)
{
    NSString* input = @"T. Rex - 1971...1977";
    NSString* result = input.humanReadableTitle;
    EXPECT_STREQ([result UTF8String], "T. Rex (1971-1977)") << "Should show artist and year range, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_YearIntervalTwoDots)
{
    NSString* input = @"T. Rex - 1971..1977";
    NSString* result = input.humanReadableTitle;
    EXPECT_STREQ([result UTF8String], "T. Rex (1971-1977)")
        << "Two-dot year range should format as (1971-1977), got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_MergedResolutionPattern)
{
    NSString* input = @"Sting - Live At The Olympia Paris.2017.BDRip1080p";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#1080p"]) << "Should contain #1080p, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"(2017)"]) << "Should contain year, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_EllipsisPreserved)
{
    NSString* input = @"Sting - ...Nothing Like The Sun - 2025 [Japan]";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"..."]) << "Should preserve ellipsis, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_ComplexCase)
{
    NSString* input = @"Kinds of Kindness (2024) WEB-DL SDR 2160p.mkv";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"#2160p"]) << "Should contain #2160p, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"(2024)"]) << "Should contain year, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"WEB-DL"]) << "Should remove WEB-DL, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"SDR"]) << "Should remove SDR, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableTitle_HyphenatedWordNoSpaces)
{
    // Hyphenated words (e.g., Butt-Head) must not get spaces around the hyphen
    NSString* input = @"Beavis.and.Butt-Head.Do";
    NSString* result = input.humanReadableTitle;
    EXPECT_TRUE([result containsString:@"Butt-Head"]) << "Should preserve Butt-Head, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"Butt - Head"]) << "Should not add spaces around hyphen, got: " << [result UTF8String];
}

class PlayButtonIconTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        tester = [[PlayButtonIconTester alloc] init];
    }

    void TearDown() override
    {
        tester = nil;
    }

    PlayButtonIconTester* tester;
};

TEST_F(PlayButtonIconTest, IconForCueFile)
{
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"audio" path:@"Album.cue"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note.list"]);
}

TEST_F(PlayButtonIconTest, IconForAudioTrack)
{
    NSString* symbolName = [tester symbolNameForType:@"track" category:@"audio" path:@"Track.mp3"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note"]);
}

TEST_F(PlayButtonIconTest, IconForAlbum)
{
    NSString* symbolName = [tester symbolNameForType:@"album" category:@"audio" path:@"AlbumFolder"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note.list"]);
}

TEST_F(PlayButtonIconTest, IconForCueFileWithFullPath)
{
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"audio" path:@"/path/to/Album - Title.cue"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note.list"]) << "CUE file with full path should show album icon";
}

TEST_F(PlayButtonIconTest, IconForCueFileUppercase)
{
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"audio" path:@"Album.CUE"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note.list"]) << "CUE file (uppercase) should show album icon";
}

TEST_F(PlayButtonIconTest, IconForOpensAsCue)
{
    // Opens .cue (album) → album icon
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"audio" path:@"Album.flac" pathToOpen:@"Album.cue"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note.list"]) << "Opens as CUE should show album icon";
}

TEST_F(PlayButtonIconTest, IconForOpensAsTrack)
{
    // Opens audio file directly (individual track) → track icon
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"audio" path:@"Track.flac" pathToOpen:@"Track.flac"];
    EXPECT_TRUE([symbolName isEqualToString:@"music.note"]) << "Opens as track should show track icon";
}

TEST_F(PlayButtonIconTest, IconForVideoFile)
{
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"video" path:@"Movie.mkv"];
    EXPECT_TRUE([symbolName isEqualToString:@"play"]) << "Video file should show play icon";
}

TEST_F(PlayButtonIconTest, IconForDVD)
{
    NSString* symbolName = [tester symbolNameForType:@"dvd" category:@"video" path:@"DVD"];
    EXPECT_TRUE([symbolName isEqualToString:@"play"]) << "DVD should show play icon";
}

TEST_F(PlayButtonIconTest, IconForBluray)
{
    NSString* symbolName = [tester symbolNameForType:@"bluray" category:@"video" path:@"Bluray"];
    EXPECT_TRUE([symbolName isEqualToString:@"play"]) << "Blu-ray should show play icon";
}

TEST_F(PlayButtonIconTest, IconForBook)
{
    NSString* symbolName = [tester symbolNameForType:@"document-books" category:@"books" path:@"Book.pdf"];
    EXPECT_TRUE([symbolName isEqualToString:@"book"]) << "Book should show book icon";
}

TEST_F(PlayButtonIconTest, IconForSoftware)
{
    NSString* symbolName = [tester symbolNameForType:@"file" category:@"software" path:@"App.dmg"];
    EXPECT_TRUE([symbolName isEqualToString:@"gearshape"]) << "Software should show gear icon";
}

TEST_F(NSStringAdditionsTest, HumanReadableEpisodeTitle_FullMoonParty)
{
    // Test that "Full-Moon Party" is preserved (hyphen in hyphenated word should be kept)
    NSString* input = @"The.White.Lotus.S03E05.Full-Moon.Party.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv";
    NSString* result = [input.lastPathComponent humanReadableEpisodeTitleWithTorrentName:@"The White Lotus - Season 3"];
    EXPECT_TRUE([result containsString:@"Full-Moon Party"]) << "Should contain 'Full-Moon Party', got: " << [result UTF8String];
    EXPECT_TRUE([result hasPrefix:@"S3 E5"]) << "Should start with season and episode, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"1080p"]) << "Should not contain technical tags, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"AMZN"]) << "Should not contain technical tags, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"EniaHD"]) << "Should not contain technical tags, got: " << [result UTF8String];
    EXPECT_FALSE([result containsString:@"H.264"]) << "Should not contain H.264, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableEpisodeTitle_ComplexEpisodeName)
{
    // Test episode title with multiple words
    NSString* input = @"Show.S01E10.The.Final.Battle.1080p.mkv";
    NSString* result = [input.lastPathComponent humanReadableEpisodeTitleWithTorrentName:@"Show - Season 1"];
    EXPECT_TRUE([result containsString:@"The Final Battle"]) << "Should contain full episode name, got: " << [result UTF8String];
    EXPECT_TRUE([result hasPrefix:@"S1 E10"]) << "Should start with season and episode, got: " << [result UTF8String];
}

TEST_F(NSStringAdditionsTest, HumanReadableEpisodeTitle_StandaloneE05_FullFilename)
{
    // Standalone E##: show full humanized filename so button title is meaningful (not just E5).
    NSString* input = @"Show.E05.Something.720p.mkv";
    NSString* result = [input.lastPathComponent humanReadableEpisodeTitleWithTorrentName:nil];
    EXPECT_TRUE([result containsString:@"E05"] || [result containsString:@"E5"]) << "Should contain episode, got: " << [result UTF8String];
    EXPECT_TRUE([result containsString:@"Show"]) << "Should contain full title, got: " << [result UTF8String];
    EXPECT_GT(result.length, (NSUInteger)3) << "Should be full filename, got: " << [result UTF8String];
}
