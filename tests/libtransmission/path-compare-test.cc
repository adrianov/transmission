// This file Copyright © Mnemosyne LLC.
// It may be used under GPLv2 (SPDX: GPL-2.0-only), GPLv3 (SPDX: GPL-3.0-only),
// or any future license endorsed by Mnemosyne LLC.
// License text can be found in the licenses/ folder.

#include <string_view>

#include <libtransmission/path-compare.h>

#include "gtest/gtest.h"

using namespace std::literals;

TEST(PathCompareTest, strverscasecmpEpisodeZeroBeforeOne)
{
    EXPECT_LT(tr_strverscasecmp("Columbo.S01E00.1968"sv, "Columbo.S01E01.1971"sv), 0);
    EXPECT_GT(tr_strverscasecmp("Columbo.S01E01.1971"sv, "Columbo.S01E00.1968"sv), 0);
}

TEST(PathCompareTest, strverscasecmpSingleDigitEpisodeBeforeTen)
{
    EXPECT_LT(tr_strverscasecmp("Show.S01E2.mkv"sv, "Show.S01E10.mkv"sv), 0);
    EXPECT_GT(tr_strverscasecmp("Show.S01E10.mkv"sv, "Show.S01E2.mkv"sv), 0);
}

TEST(PathCompareTest, comparePathsColumboSeasonOne)
{
    auto const e00 = "Columbo.S01.1968-1972/Columbo.S01E00.1968.Prescription.Murder.720p.BluRay.Rus.Eng.HDCLUB.mkv"sv;
    auto const e01 = "Columbo.S01.1968-1972/Columbo.S01E01.1971.Ransom.for.a.Dead.Man.720p.BluRay.Rus.Eng.HDCLUB.mkv"sv;
    auto const e02 = "Columbo.S01.1968-1972/Columbo.S01E02.1971.Murder.by.the.Book.720p.BluRay.Rus.Eng.HDCLUB.mkv"sv;

    EXPECT_LT(tr_compare_paths_for_piece_priority(e00, e01), 0);
    EXPECT_LT(tr_compare_paths_for_piece_priority(e01, e02), 0);
    EXPECT_LT(tr_compare_paths_for_piece_priority(e00, e02), 0);
}

TEST(PathCompareTest, comparePathsBonusFileAfterMain)
{
    auto const main_file = "Season/file.mkv"sv;
    auto const bonus_file = "Season/file.Bonus.mkv"sv;

    EXPECT_LT(tr_compare_paths_for_piece_priority(main_file, bonus_file), 0);
    EXPECT_GT(tr_compare_paths_for_piece_priority(bonus_file, main_file), 0);
}

TEST(PathCompareTest, strequalcaseIgnoresCase)
{
    EXPECT_TRUE(tr_strequalcase("ABC.mkv"sv, "abc.mkv"sv));
    EXPECT_FALSE(tr_strequalcase("abc.mkv"sv, "abd.mkv"sv));
}
