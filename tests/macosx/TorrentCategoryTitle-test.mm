// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <gtest/gtest.h>

#import "TorrentCategoryTitle.h"

TEST(TorrentCategoryTitleTest, detectsVideoFromReleaseTags)
{
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"Enron The Smartest Guys In The Room 2005 1080p 6ch 6subs x265"));
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"Enron The Smartest Guys In The Room 2005 1080p AMZN WEB-DL H264-GPRS"));
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"Enron_-_The_Smartest_Guys_In_The_Room.avi"));
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"RuPauls Drag Race S12E07 Madonna The Unauthorized Rusical 1080p AMZN WEB-DL"));
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"Madonna Truth or Dare (1991) BDRip 1080p DTS HighCode- PublicHD"));
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"Britney Spears ft.Madonna - Me Against The Music (MusicVideo)"));
}

TEST(TorrentCategoryTitleTest, detectsAudioFromReleaseTags)
{
    EXPECT_EQ(@"audio", TorrentMediaCategoryFromTitle(@"Madonna - Rebel Heart (Deluxe) (2026 Pop) [Flac 16-44]"));
    EXPECT_EQ(@"audio", TorrentMediaCategoryFromTitle(@"Madonna - MDNA (Deluxe) (2026 Pop) [Flac 24-44]"));
    EXPECT_EQ(@"audio", TorrentMediaCategoryFromTitle(@"Madonna - Greatest Hits 2CD [2008] 320 vtwin88cube"));
    EXPECT_EQ(@"audio", TorrentMediaCategoryFromTitle(@"Madonna - Bedtime Stories – The Untold Chapter (2025) Mp3 (320kbps) [Hunter]"));
}

TEST(TorrentCategoryTitleTest, detectsBooksFromReleaseTags)
{
    EXPECT_EQ(@"books", TorrentMediaCategoryFromTitle(@"Sex (Book) by Madonna 1992"));
    EXPECT_EQ(@"books", TorrentMediaCategoryFromTitle(@"The First Tycoon by T. J. Stiles EPUB"));
}

TEST(TorrentCategoryTitleTest, detectsSoftwareFromReleaseTags)
{
    EXPECT_EQ(@"software", TorrentMediaCategoryFromTitle(@"RollerCoaster Tycoon 2 Triple Thrill Pack GoG"));
    EXPECT_EQ(@"software", TorrentMediaCategoryFromTitle(@"Game Dev Tycoon v1.8.6"));
    EXPECT_EQ(@"software", TorrentMediaCategoryFromTitle(@"MICROSOFT Office PRO Plus 2016 v16.0.4266.1003 RTM + Activator"));
    EXPECT_EQ(@"software", TorrentMediaCategoryFromTitle(@"Blood Bar Tycoon-TENOKE"));
}

TEST(TorrentCategoryTitleTest, detectsAdultFromReleaseTags)
{
    EXPECT_EQ(@"adult", TorrentMediaCategoryFromTitle(@"Her Older Sister's Close-contact Training Ha JUR-701 (Madonna) 2026 WEB-DL 1080p"));
    EXPECT_EQ(@"adult", TorrentMediaCategoryFromTitle(@"PrimalFetish 22 02 25 Madonna And Paris XXX 480p MP4-XXX [XC]"));
}

TEST(TorrentCategoryTitleTest, prefersAudioOverAmbiguousArtistName)
{
    EXPECT_EQ(@"audio", TorrentMediaCategoryFromTitle(@"Madonna - Like a Prayer [1989] [2016] [Japan Remaster] [FLAC]-Sc4r3cr0w"));
    EXPECT_EQ(@"video", TorrentMediaCategoryFromTitle(@"Evita (1996) Madonna, Antonio Banderas .x264 mkv"));
}

TEST(TorrentCategoryTitleTest, returnsNilWhenUnknown)
{
    EXPECT_EQ(nil, TorrentMediaCategoryFromTitle(@"Money Effects, Enron, Walmart, Tobacco, Outsourcing, Olympics, D"));
    EXPECT_EQ(nil, TorrentMediaCategoryFromTitle(@""));
    EXPECT_EQ(nil, TorrentMediaCategoryFromTitle(nil));
}
