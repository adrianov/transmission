// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// NSSearchFieldDelegate: toolbar/filter search sync, Enter-to-search, placeholder and external search.

#import "ControllerPrivate.h"
#import "FilterBarController.h"
#import "Torrent.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (Search)

- (void)controlTextDidEndEditing:(NSNotification*)notification
{
    NSSearchField* searchField = notification.object;
    if ([searchField isKindOfClass:[NSSearchField class]])
    {
        NSNumber* textMovement = notification.userInfo[@"NSTextMovement"];
        if (textMovement.integerValue == NSReturnTextMovement)
        {
            NSString* query = searchField.stringValue;
            if (query.length > 0)
            {
                [self searchTorrentsWithQuery:query];
                [self resetSearchFilterIfNeededForSearchField:self.fToolbarSearchField];
                [self resetSearchFilterIfNeededForSearchField:self.fFilterBar.fSearchField];
            }
        }
    }
}

- (void)resetSearchFilterIfNeededForSearchField:(NSSearchField*)searchField
{
    if (searchField.stringValue.length == 0)
        return;
    if (self.fTableView.numberOfRows != 0)
        return;

    self.fToolbarSearchField.stringValue = @"";
    self.fFilterBar.fSearchField.stringValue = @"";
    [self applyFilter];
}

- (void)controlTextDidChange:(NSNotification*)notification
{
    NSSearchField* searchField = notification.object;
    if ([searchField isKindOfClass:[NSSearchField class]])
    {
        if (searchField == self.fToolbarSearchField)
            self.fFilterBar.fSearchField.stringValue = searchField.stringValue;
        else if (searchField == self.fFilterBar.fSearchField)
            self.fToolbarSearchField.stringValue = searchField.stringValue;

        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyFilter) object:nil];
        [self performSelector:@selector(applyFilter) withObject:nil afterDelay:0.12];
    }
}

- (void)updateSearchPlaceholder
{
    NSMutableSet<NSString*>* searchDomains = [NSMutableSet setWithArray:@[ @"rutracker.org", @"kinozal.tv", @"nnmclub.to" ]];

    NSError* error = nil;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"(https?://[^/]+/).*(viewtopic|details|browse)\\.php"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];

    NSCountedSet<NSString*>* domainCounts = [[NSCountedSet alloc] init];
    for (Torrent* torrent in self.fTorrents)
    {
        NSString* comment = torrent.comment;
        if (comment.length == 0)
            continue;

        NSMutableSet<NSString*>* foundInThisTorrent = [NSMutableSet set];
        for (NSString* domain in searchDomains)
        {
            if ([comment rangeOfString:domain options:NSCaseInsensitiveSearch].location != NSNotFound)
                [foundInThisTorrent addObject:domain];
        }
        [regex enumerateMatchesInString:comment options:0 range:NSMakeRange(0, comment.length)
                             usingBlock:^(NSTextCheckingResult* result, NSMatchingFlags /*flags*/, BOOL* /*stop*/) {
                                 NSString* baseUrl = [comment substringWithRange:[result rangeAtIndex:1]];
                                 NSURL* url = [NSURL URLWithString:baseUrl];
                                 NSString* domain = url.host.lowercaseString;
                                 if (domain)
                                     [foundInThisTorrent addObject:domain];
                             }];
        for (NSString* domain in foundInThisTorrent)
            [domainCounts addObject:domain];
    }

    NSString* topDomain = @"rutracker.org";
    if (domainCounts.count > 0)
    {
        NSArray<NSString*>* sortedDomains = [domainCounts.allObjects
            sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
                return [@([domainCounts countForObject:b]) compare:@([domainCounts countForObject:a])];
            }];
        topDomain = sortedDomains[0];
    }

    NSString* placeholder = [NSString
        stringWithFormat:NSLocalizedString(@"Press Enter to Search on %@...", "Search toolbar item -> placeholder"), topDomain];
    if (![self.fToolbarSearchField.placeholderString isEqualToString:placeholder])
        self.fToolbarSearchField.placeholderString = placeholder;
    if (![self.fFilterBar.fSearchField.placeholderString isEqualToString:placeholder])
        self.fFilterBar.fSearchField.placeholderString = placeholder;
}

- (void)searchTorrentsWithQuery:(NSString*)query
{
    NSMutableDictionary<NSString*, NSString*>* searchTemplates = [@{ @"kinozal.tv" : @"https://kinozal.tv/browse.php?s=%@&t=1" } mutableCopy];

    NSError* error = nil;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"(https?://[^/]+/forum/)viewtopic\\.php"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];

    NSCountedSet<NSString*>* domainCounts = [[NSCountedSet alloc] init];
    for (Torrent* torrent in self.fTorrents)
    {
        NSString* comment = torrent.comment;
        if (comment.length == 0)
            continue;

        NSMutableSet<NSString*>* foundInThisTorrent = [NSMutableSet set];
        for (NSString* domain in searchTemplates.allKeys)
        {
            if ([comment rangeOfString:domain options:NSCaseInsensitiveSearch].location != NSNotFound)
                [foundInThisTorrent addObject:domain];
        }
        [regex enumerateMatchesInString:comment options:0 range:NSMakeRange(0, comment.length)
                             usingBlock:^(NSTextCheckingResult* result, NSMatchingFlags /*flags*/, BOOL* /*stop*/) {
                                 NSString* baseUrl = [comment substringWithRange:[result rangeAtIndex:1]];
                                 NSURL* url = [NSURL URLWithString:baseUrl];
                                 NSString* domain = url.host.lowercaseString;
                                 if (domain)
                                 {
                                     if (!searchTemplates[domain])
                                         searchTemplates[domain] = [baseUrl stringByAppendingString:@"tracker.php?nm=%@&o=10"];
                                     [foundInThisTorrent addObject:domain];
                                 }
                             }];
        for (NSString* domain in foundInThisTorrent)
            [domainCounts addObject:domain];
    }

    if (domainCounts.count == 0)
        return;

    NSArray<NSString*>* sortedDomains = [domainCounts.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
        return [@([domainCounts countForObject:a]) compare:@([domainCounts countForObject:b])];
    }];

    NSString* encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;

    for (NSString* domain in sortedDomains)
    {
        NSString* urlTemplate = searchTemplates[domain];
        NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:urlTemplate, encodedQuery]];
        [NSWorkspace.sharedWorkspace openURL:url configuration:configuration completionHandler:nil];
    }
}

@end
#pragma clang diagnostic pop
