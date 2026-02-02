// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>

#import "Torrent.h"
#import "TorrentPrivate.h"

typedef NS_ENUM(NSUInteger, TorrentSearchMatchKind) {
    TorrentSearchMatchKindNone = 0,
    TorrentSearchMatchKindSubstring = 1,
    TorrentSearchMatchKindWordStart = 2,
    TorrentSearchMatchKindFullWord = 3
};

typedef NS_ENUM(NSUInteger, TorrentSearchRelevanceTier) {
    TorrentSearchRelevanceTierAllWordsMatch = 1,
    TorrentSearchRelevanceTierWordsInFirstThreeWords = 2,
    TorrentSearchRelevanceTierFullQueryAtStart = 3
};

static NSUInteger const kTorrentSearchTierMultiplier = 10000;

typedef struct
{
    BOOL allStringsMatched;
    NSUInteger totalScore;
    TorrentSearchRelevanceTier relevanceTier;
} TorrentSearchResult;

static NSUInteger endOfWordIndexAfterWordCount(NSString* text, NSUInteger wordCount)
{
    static NSCharacterSet* alnum = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        alnum = NSCharacterSet.alphanumericCharacterSet;
    });
    NSUInteger len = text.length;
    NSUInteger count = 0;
    NSUInteger i = 0;
    while (i < len && count < wordCount)
    {
        while (i < len && ![alnum characterIsMember:[text characterAtIndex:i]])
            i++;
        if (i >= len)
            break;
        count++;
        if (count == wordCount)
        {
            while (i < len && [alnum characterIsMember:[text characterAtIndex:i]])
                i++;
            return i;
        }
        while (i < len && [alnum characterIsMember:[text characterAtIndex:i]])
            i++;
    }
    return len;
}

static BOOL isMatchRangeInFirstThreeWords(NSString* text, NSRange range)
{
    return range.location < endOfWordIndexAfterWordCount(text, 3);
}

static void getSearchMatchInText(NSString* searchString, NSString* text, NSStringCompareOptions opts, TorrentSearchMatchKind* outKind, BOOL* outAtStringStart, BOOL* outInFirstThreeWords)
{
    *outKind = TorrentSearchMatchKindNone;
    *outAtStringStart = NO;
    *outInFirstThreeWords = NO;
    if (searchString.length == 0 || text.length == 0)
        return;
    NSRange range = [text rangeOfString:searchString options:opts];
    if (range.location == NSNotFound)
        return;
    *outAtStringStart = (range.location == 0);
    *outInFirstThreeWords = isMatchRangeInFirstThreeWords(text, range);
    static NSCharacterSet* alnum = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        alnum = NSCharacterSet.alphanumericCharacterSet;
    });
    BOOL wordStart = range.location == 0 || ![alnum characterIsMember:[text characterAtIndex:range.location - 1]];
    NSUInteger end = range.location + range.length;
    BOOL wordEnd = end >= text.length || ![alnum characterIsMember:[text characterAtIndex:end]];
    if (wordStart && wordEnd)
        *outKind = TorrentSearchMatchKindFullWord;
    else if (wordStart)
        *outKind = TorrentSearchMatchKindWordStart;
    else
        *outKind = TorrentSearchMatchKindSubstring;
}

static NSUInteger scoreForSearchMatch(TorrentSearchMatchKind kind, BOOL atStringStart)
{
    NSUInteger score = (NSUInteger)kind;
    if (atStringStart)
        score += 1;
    return score;
}

static TorrentSearchRelevanceTier computeRelevanceTier(BOOL fullQueryAtStart, NSArray<NSNumber*>* tokenInFirstThreeWords)
{
    if (fullQueryAtStart)
        return TorrentSearchRelevanceTierFullQueryAtStart;
    for (NSNumber* n in tokenInFirstThreeWords)
        if (!n.boolValue)
            return TorrentSearchRelevanceTierAllWordsMatch;
    return TorrentSearchRelevanceTierWordsInFirstThreeWords;
}

static TorrentSearchResult computeSearchResult(NSArray<NSString*>* strings, NSArray<NSString*>* texts, NSStringCompareOptions opts)
{
    TorrentSearchResult r = { .allStringsMatched = YES, .totalScore = 0, .relevanceTier = TorrentSearchRelevanceTierAllWordsMatch };
    if (strings.count == 0)
        return r;
    NSString* fullQuery = [strings componentsJoinedByString:@" "];
    BOOL fullQueryAtStart = NO;
    for (NSString* text in texts)
    {
        if (fullQuery.length > 0 && [text rangeOfString:fullQuery options:opts].location == 0)
        {
            fullQueryAtStart = YES;
            break;
        }
    }
    NSMutableArray<NSNumber*>* tokenInFirstThreeWords = [NSMutableArray arrayWithCapacity:strings.count];
    for (NSString* searchString in strings)
    {
        NSUInteger best = 0;
        BOOL inFirstThree = NO;
        for (NSString* text in texts)
        {
            TorrentSearchMatchKind kind;
            BOOL atStart;
            BOOL inFirst3;
            getSearchMatchInText(searchString, text, opts, &kind, &atStart, &inFirst3);
            if (inFirst3)
                inFirstThree = YES;
            NSUInteger score = scoreForSearchMatch(kind, atStart);
            if (score > best)
                best = score;
        }
        [tokenInFirstThreeWords addObject:@(inFirstThree)];
        if (best == 0)
            r.allStringsMatched = NO;
        r.totalScore += best;
    }
    if (r.allStringsMatched)
        r.relevanceTier = computeRelevanceTier(fullQueryAtStart, tokenInFirstThreeWords);
    return r;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (Search)

- (Torrent*)selfForSorting
{
    return self;
}

- (NSArray<NSString*>*)searchableTextsByTracker:(BOOL)byTracker includePlayableTitles:(BOOL)includePlayableTitles
{
    if (byTracker)
        return self.allTrackersFlat;
    NSMutableArray<NSString*>* texts = [NSMutableArray arrayWithObject:self.name];
    if (includePlayableTitles)
    {
        for (NSDictionary* item in self.playableFiles)
        {
            NSString* baseTitle = item[@"baseTitle"];
            if (baseTitle.length > 0)
                [texts addObject:baseTitle];
        }
    }
    return texts;
}

- (BOOL)matchesSearchStrings:(NSArray<NSString*>*)strings
                   byTracker:(BOOL)byTracker
       includePlayableTitles:(BOOL)includePlayableTitles
{
    if (strings.count == 0)
        return YES;
    NSStringCompareOptions const opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSArray<NSString*>* texts = [self searchableTextsByTracker:byTracker includePlayableTitles:includePlayableTitles];
    return computeSearchResult(strings, texts, opts).allStringsMatched;
}

- (NSUInteger)searchMatchScoreForStrings:(NSArray<NSString*>*)strings
                               byTracker:(BOOL)byTracker
                   includePlayableTitles:(BOOL)includePlayableTitles
{
    if (strings.count == 0)
        return 0;
    NSStringCompareOptions const opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSArray<NSString*>* texts = [self searchableTextsByTracker:byTracker includePlayableTitles:includePlayableTitles];
    TorrentSearchResult result = computeSearchResult(strings, texts, opts);
    return result.relevanceTier * kTorrentSearchTierMultiplier + result.totalScore;
}

@end
#pragma clang diagnostic pop
