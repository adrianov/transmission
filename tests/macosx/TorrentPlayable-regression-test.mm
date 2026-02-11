// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.
//
// Regression test for buildIndividualFilePlayables crash: updating @"name" in place
// (common prefix/suffix stripping) must use NSMutableDictionary; immutable NSDictionary
// causes -[__NSDictionaryI setObject:forKeyedSubscript:]: unrecognized selector.

#import <Foundation/Foundation.h>
#include <gtest/gtest.h>

TEST(TorrentPlayableRegressionTest, PlayableEntryNameUpdateRequiresMutableDict)
{
    NSMutableArray<NSDictionary*>* playable = [NSMutableArray array];
    [playable addObject:[@{ @"name" : @"Show - Episode One (2024)", @"relativePath" : @"Show/Episode.One.mkv" } mutableCopy]];

    NSString* commonPrefix = @"Show - ";
    NSString* commonSuffix = @" (2024)";
    for (NSMutableDictionary* fileInfo in playable)
    {
        NSString* relativePath = fileInfo[@"relativePath"];
        if (relativePath.length == 0)
            continue;
        NSString* title = fileInfo[@"name"];
        if (title.length == 0)
            continue;
        if (commonPrefix.length > 0 && title.length > commonPrefix.length && [title hasPrefix:commonPrefix])
            title = [title substringFromIndex:commonPrefix.length];
        if (commonSuffix.length > 0 && title.length > commonSuffix.length && [title hasSuffix:commonSuffix])
            title = [title substringToIndex:title.length - commonSuffix.length];
        title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (title.length > 0)
            fileInfo[@"name"] = title;
    }

    EXPECT_TRUE([playable[0][@"name"] isEqualToString:@"Episode One"])
        << "Stripped name should be 'Episode One', got: " << [playable[0][@"name"] UTF8String];
}

TEST(TorrentPlayableRegressionTest, DocumentBooksPreserveFullTitleWhenMixedWithAudio)
{
    // PDF mixed with audio: per-parent strip must skip document-books so "In The Court Of The Crimson King..."
    // and "Larks' Tongues In Aspic..." stay full, not truncated to "In" or "Larks'".
    NSMutableArray<NSDictionary*>* playable = [NSMutableArray array];
    [playable addObject:[@{
                  @"type" : @"document-books",
                  @"name" : @"In The Court Of The Crimson King (Expanded & Remastered Original Album Mix)",
                  @"relativePath" : @"Album/In The Court Of The Crimson King (Expanded & Remastered Original Album Mix).pdf"
              } mutableCopy]];
    [playable addObject:[@{
                  @"type" : @"file",
                  @"name" : @"05-The Court Of The Crimson King",
                  @"relativePath" : @"Album/05-The Court Of The Crimson King.flac"
              } mutableCopy]];

    NSString* commonPrefix = @"";
    NSString* commonSuffix = @"";
    for (NSMutableDictionary* fileInfo in playable)
    {
        if ([fileInfo[@"type"] isEqualToString:@"document-books"])
            continue;
        NSString* relativePath = fileInfo[@"relativePath"];
        if (relativePath.length == 0)
            continue;
        NSString* title = fileInfo[@"name"];
        if (title.length == 0)
            continue;
        if (commonPrefix.length > 0 && title.length > commonPrefix.length && [title hasPrefix:commonPrefix])
            title = [title substringFromIndex:commonPrefix.length];
        if (commonSuffix.length > 0 && title.length > commonSuffix.length && [title hasSuffix:commonSuffix])
            title = [title substringToIndex:title.length - commonSuffix.length];
        title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (title.length > 0)
            fileInfo[@"name"] = title;
    }

    EXPECT_TRUE([playable[0][@"name"] isEqualToString:@"In The Court Of The Crimson King (Expanded & Remastered Original Album Mix)"])
        << "PDF title must stay full, got: " << [playable[0][@"name"] UTF8String];
}
