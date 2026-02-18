// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Sort menu, filter bar, and transfers table list/refresh. Keeps sort/filter logic out of main Controller.

#include <atomic>

#import "ControllerPrivate.h"
#import "ControllerConstants.h"
#import "FilterBarController.h"
#import "NSMutableArrayAdditions.h"
#import "GroupsController.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (FilterSort)

- (void)setSort:(id)sender
{
    SortType sortType;
    NSMenuItem* senderMenuItem = sender;
    switch (senderMenuItem.tag)
    {
    case SortTagOrder:
        sortType = SortTypeOrder;
        [self.fDefaults setBool:NO forKey:@"SortReverse"];
        break;
    case SortTagDate:
        sortType = SortTypeDate;
        break;
    case SortTagName:
        sortType = SortTypeName;
        break;
    case SortTagProgress:
        sortType = SortTypeProgress;
        break;
    case SortTagState:
        sortType = SortTypeState;
        break;
    case SortTagTracker:
        sortType = SortTypeTracker;
        break;
    case SortTagActivity:
        sortType = SortTypeActivity;
        break;
    case SortTagSize:
        sortType = SortTypeSize;
        break;
    case SortTagETA:
        sortType = SortTypeETA;
        break;
    default:
        NSAssert1(NO, @"Unknown sort tag received: %ld", senderMenuItem.tag);
        return;
    }

    [self.fDefaults setObject:sortType forKey:@"Sort"];

    [self sortTorrentsAndIncludeQueueOrder:YES];
}

- (void)setSortByGroup:(id)sender
{
    BOOL sortByGroup = ![self.fDefaults boolForKey:@"SortByGroup"];
    [self.fDefaults setBool:sortByGroup forKey:@"SortByGroup"];

    [self applyFilter];
}

- (void)setSortReverse:(id)sender
{
    BOOL const setReverse = ((NSMenuItem*)sender).tag == SortOrderTagDescending;
    if (setReverse != [self.fDefaults boolForKey:@"SortReverse"])
    {
        [self.fDefaults setBool:setReverse forKey:@"SortReverse"];
        [self sortTorrentsAndIncludeQueueOrder:NO];
    }
}

- (void)sortTorrentsAndIncludeQueueOrder:(BOOL)includeQueueOrder
{
    [self sortTorrentsCallUpdates:YES includeQueueOrder:includeQueueOrder];
    self.fTableView.needsDisplay = YES;
}

- (void)sortTorrentsCallUpdates:(BOOL)callUpdates includeQueueOrder:(BOOL)includeQueueOrder
{
    BOOL const asc = ![self.fDefaults boolForKey:@"SortReverse"];

    NSArray* descriptors;
    NSSortDescriptor* nameDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:asc
                                                                      selector:@selector(localizedStandardCompare:)];

    NSString* sortType = [self.fDefaults stringForKey:@"Sort"];
    if ([sortType isEqualToString:SortTypeState])
    {
        NSSortDescriptor* stateDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"stateSortKey" ascending:!asc];
        NSSortDescriptor* progressDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"progress" ascending:!asc];
        NSSortDescriptor* ratioDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"ratio" ascending:!asc];

        descriptors = @[ stateDescriptor, progressDescriptor, ratioDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeProgress])
    {
        NSSortDescriptor* progressDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"progress" ascending:asc];
        NSSortDescriptor* ratioProgressDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"progressStopRatio" ascending:asc];
        NSSortDescriptor* ratioDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"ratio" ascending:asc];

        descriptors = @[ progressDescriptor, ratioProgressDescriptor, ratioDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeETA])
    {
        NSSortDescriptor* etaDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"eta" ascending:asc];
        NSSortDescriptor* progressDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"progress" ascending:asc];
        NSSortDescriptor* ratioProgressDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"progressStopRatio" ascending:asc];
        NSSortDescriptor* ratioDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"ratio" ascending:asc];

        descriptors = @[ etaDescriptor, progressDescriptor, ratioProgressDescriptor, ratioDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeTracker])
    {
        NSSortDescriptor* trackerDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"trackerSortKey" ascending:asc
                                                                             selector:@selector(localizedCaseInsensitiveCompare:)];

        descriptors = @[ trackerDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeActivity])
    {
        NSSortDescriptor* rateDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"totalRate" ascending:asc];
        NSSortDescriptor* activityDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"dateActivityOrAdd" ascending:asc];

        descriptors = @[ rateDescriptor, activityDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeDate])
    {
        NSSortDescriptor* dateDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"dateAdded" ascending:asc];

        descriptors = @[ dateDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeSize])
    {
        NSSortDescriptor* sizeDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"totalSizeSelected" ascending:asc];

        descriptors = @[ sizeDescriptor, nameDescriptor ];
    }
    else if ([sortType isEqualToString:SortTypeName])
    {
        descriptors = @[ nameDescriptor ];
    }
    else
    {
        NSAssert1([sortType isEqualToString:SortTypeOrder], @"Unknown sort type received: %@", sortType);

        if (!includeQueueOrder)
        {
            return;
        }

        NSSortDescriptor* orderDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"queuePosition" ascending:asc];

        descriptors = @[ orderDescriptor ];
    }

    NSArray<NSString*>* searchStrings = [self.fToolbarSearchField.stringValue
        nonEmptyComponentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (searchStrings.count == 0)
        searchStrings = nil;
    if (searchStrings.count > 0)
    {
        BOOL const filterTracker = [[self.fDefaults stringForKey:@"FilterSearchType"] isEqualToString:FilterSearchTypeTracker];
        BOOL const includePlayable = [self.fDefaults boolForKey:@"ShowContentButtons"];
        NSSortDescriptor* matchDescriptor = [NSSortDescriptor
            sortDescriptorWithKey:@"selfForSorting"
                        ascending:NO comparator:^NSComparisonResult(Torrent* a, Torrent* b) {
                            NSUInteger const sa = [a searchMatchScoreForStrings:searchStrings byTracker:filterTracker
                                                          includePlayableTitles:includePlayable];
                            NSUInteger const sb = [b searchMatchScoreForStrings:searchStrings byTracker:filterTracker
                                                          includePlayableTitles:includePlayable];
                            if (sa > sb)
                                return NSOrderedDescending;
                            if (sa < sb)
                                return NSOrderedAscending;
                            return NSOrderedSame;
                        }];
        descriptors = [@[ matchDescriptor ] arrayByAddingObjectsFromArray:descriptors];
    }

    BOOL beganTableUpdate = !callUpdates;

    if ([self.fDefaults boolForKey:@"SortByGroup"])
    {
        for (TorrentGroup* group in self.fDisplayedTorrents)
        {
            [self rearrangeTorrentTableArray:group.torrents forParent:group withSortDescriptors:descriptors
                            beganTableUpdate:&beganTableUpdate];
        }
    }
    else
    {
        [self rearrangeTorrentTableArray:self.fDisplayedTorrents forParent:nil withSortDescriptors:descriptors
                        beganTableUpdate:&beganTableUpdate];
    }

    if (beganTableUpdate && callUpdates)
    {
        [self.fTableView endUpdates];
    }
}

- (void)rearrangeTorrentTableArray:(NSMutableArray*)rearrangeArray
                         forParent:parent
               withSortDescriptors:(NSArray*)descriptors
                  beganTableUpdate:(BOOL*)beganTableUpdate
{
    for (NSUInteger currentIndex = 1; currentIndex < rearrangeArray.count; ++currentIndex)
    {
        NSUInteger const insertIndex = [rearrangeArray indexOfObject:rearrangeArray[currentIndex]
                                                       inSortedRange:NSMakeRange(0, currentIndex)
                                                             options:(NSBinarySearchingInsertionIndex | NSBinarySearchingLastEqual)
                                                     usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                         for (NSSortDescriptor* descriptor in descriptors)
                                                         {
                                                             NSComparisonResult const result = [descriptor compareObject:obj1
                                                                                                                toObject:obj2];
                                                             if (result != NSOrderedSame)
                                                             {
                                                                 return result;
                                                             }
                                                         }

                                                         return NSOrderedSame;
                                                     }];

        if (insertIndex != currentIndex)
        {
            if (!*beganTableUpdate)
            {
                *beganTableUpdate = YES;
                [self.fTableView beginUpdates];
            }

            [rearrangeArray moveObjectAtIndex:currentIndex toIndex:insertIndex];
            [self.fTableView moveItemAtIndex:currentIndex inParent:parent toIndex:insertIndex inParent:parent];
        }
    }

    NSAssert2(
        [rearrangeArray isEqualToArray:[rearrangeArray sortedArrayUsingDescriptors:descriptors]],
        @"Torrent rearranging didn't work! %@ %@",
        rearrangeArray,
        [rearrangeArray sortedArrayUsingDescriptors:descriptors]);
}

- (void)applyFilter
{
    NSString* filterType = [self.fDefaults stringForKey:@"Filter"];
    BOOL filterActive = NO, filterDownload = NO, filterSeed = NO, filterPause = NO, filterError = NO, filterStatus = YES;
    if ([filterType isEqualToString:FilterTypeActive])
    {
        filterActive = YES;
    }
    else if ([filterType isEqualToString:FilterTypeDownload])
    {
        filterDownload = YES;
    }
    else if ([filterType isEqualToString:FilterTypeSeed])
    {
        filterSeed = YES;
    }
    else if ([filterType isEqualToString:FilterTypePause])
    {
        filterPause = YES;
    }
    else if ([filterType isEqualToString:FilterTypeError])
    {
        filterError = YES;
    }
    else
    {
        filterStatus = NO;
    }

    NSInteger const groupFilterValue = [self.fDefaults integerForKey:@"FilterGroup"];
    BOOL const filterGroup = groupFilterValue != kGroupFilterAllTag;

    NSArray<NSString*>* searchStrings = [self.fToolbarSearchField.stringValue
        nonEmptyComponentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (searchStrings && searchStrings.count == 0)
    {
        searchStrings = nil;
    }
    BOOL const filterTracker = searchStrings && [[self.fDefaults stringForKey:@"FilterSearchType"] isEqualToString:FilterSearchTypeTracker];

    std::atomic<int32_t> active{ 0 }, downloading{ 0 }, seeding{ 0 }, paused{ 0 }, error{ 0 };
    auto* activeRef = &active;
    auto* downloadingRef = &downloading;
    auto* seedingRef = &seeding;
    auto* pausedRef = &paused;
    auto* errorRef = &error;

    NSIndexSet* indexesOfNonFilteredTorrents = [self.fTorrents
        indexesOfObjectsWithOptions:NSEnumerationConcurrent
                        passingTest:^BOOL(Torrent* torrent, NSUInteger /*torrentIdx*/, BOOL* /*stopTorrentsEnumeration*/) {
                            if (torrent.active && !torrent.checkingWaiting)
                            {
                                BOOL const isActive = torrent.transmitting;
                                if (isActive)
                                {
                                    std::atomic_fetch_add_explicit(activeRef, 1, std::memory_order_relaxed);
                                }

                                if (torrent.seeding)
                                {
                                    std::atomic_fetch_add_explicit(seedingRef, 1, std::memory_order_relaxed);
                                    if (filterStatus && !((filterActive && isActive) || filterSeed))
                                    {
                                        return NO;
                                    }
                                }
                                else
                                {
                                    std::atomic_fetch_add_explicit(downloadingRef, 1, std::memory_order_relaxed);
                                    if (filterStatus && !((filterActive && isActive) || filterDownload))
                                    {
                                        return NO;
                                    }
                                }
                            }
                            else if (torrent.error)
                            {
                                std::atomic_fetch_add_explicit(errorRef, 1, std::memory_order_relaxed);
                                if (filterStatus && !filterError)
                                {
                                    return NO;
                                }
                            }
                            else
                            {
                                std::atomic_fetch_add_explicit(pausedRef, 1, std::memory_order_relaxed);
                                if (filterStatus && !filterPause)
                                {
                                    return NO;
                                }
                            }

                            if (filterGroup)
                                if (torrent.groupValue != groupFilterValue)
                                {
                                    return NO;
                                }

                            if (searchStrings)
                            {
                                BOOL const includePlayable = [self.fDefaults boolForKey:@"ShowContentButtons"];
                                if (![torrent matchesSearchStrings:searchStrings byTracker:filterTracker
                                             includePlayableTitles:includePlayable])
                                    return NO;
                            }

                            return YES;
                        }];

    NSArray<Torrent*>* allTorrents = [self.fTorrents objectsAtIndexes:indexesOfNonFilteredTorrents];

    if (self.fFilterBar)
    {
        [self.fFilterBar setCountAll:self.fTorrents.count active:active.load() downloading:downloading.load()
                             seeding:seeding.load()
                              paused:paused.load()
                               error:error.load()];
    }

    BOOL const groupRows = allTorrents.count > 0 ?
        [self.fDefaults boolForKey:@"SortByGroup"] :
        (self.fDisplayedTorrents.count > 0 && [self.fDisplayedTorrents[0] isKindOfClass:[TorrentGroup class]]);
    BOOL const wasGroupRows = self.fDisplayedTorrents.count > 0 ? [self.fDisplayedTorrents[0] isKindOfClass:[TorrentGroup class]] : groupRows;

    if (self.fDisplayedTorrents.count > 0)
    {
        void (^removePreviousFinishedPieces)(id, NSUInteger, BOOL*) = ^(Torrent* torrent, NSUInteger /*idx*/, BOOL* /*stop*/) {
            if (![allTorrents containsObject:torrent])
            {
                torrent.previousFinishedPieces = nil;
            }
        };

        if (wasGroupRows)
        {
            [self.fDisplayedTorrents
                enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(id obj, NSUInteger /*idx*/, BOOL* /*stop*/) {
                    [((TorrentGroup*)obj).torrents enumerateObjectsWithOptions:NSEnumerationConcurrent
                                                                    usingBlock:removePreviousFinishedPieces];
                }];
        }
        else
        {
            [self.fDisplayedTorrents enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:removePreviousFinishedPieces];
        }
    }

    BOOL beganUpdates = NO;

    [NSAnimationContext beginGrouping];
    NSAnimationContext.currentContext.duration = 0;

    if (!groupRows && !wasGroupRows)
    {
        NSMutableIndexSet* addIndexes = [NSMutableIndexSet indexSet];
        NSMutableIndexSet* removePreviousIndexes = [NSMutableIndexSet
            indexSetWithIndexesInRange:NSMakeRange(0, self.fDisplayedTorrents.count)];

        [allTorrents enumerateObjectsWithOptions:0 usingBlock:^(Torrent* obj, NSUInteger previousIndex, BOOL* /*stopEnumerate*/) {
            NSUInteger const currentIndex = [self.fDisplayedTorrents
                indexOfObjectAtIndexes:removePreviousIndexes
                               options:NSEnumerationConcurrent
                           passingTest:^BOOL(id objDisplay, NSUInteger /*idx*/, BOOL* /*stop*/) {
                               return obj == objDisplay;
                           }];
            if (currentIndex == NSNotFound)
            {
                [addIndexes addIndex:previousIndex];
            }
            else
            {
                [removePreviousIndexes removeIndex:currentIndex];
            }
        }];

        if (addIndexes.count > 0 || removePreviousIndexes.count > 0)
        {
            beganUpdates = YES;
            [self.fTableView beginUpdates];

            if (removePreviousIndexes.count > 0)
            {
                [self.fDisplayedTorrents removeObjectsAtIndexes:removePreviousIndexes];
                [self.fTableView removeItemsAtIndexes:removePreviousIndexes inParent:nil withAnimation:NSTableViewAnimationSlideDown];
            }

            if (addIndexes.count > 0)
            {
                if (self.fAddingTransfers)
                {
                    NSIndexSet* newAddIndexes = [allTorrents
                        indexesOfObjectsAtIndexes:addIndexes
                                          options:NSEnumerationConcurrent
                                      passingTest:^BOOL(Torrent* obj, NSUInteger /*idx*/, BOOL* /*stop*/) {
                                          return [self.fAddingTransfers containsObject:obj];
                                      }];

                    [addIndexes removeIndexes:newAddIndexes];

                    NSArray* newTorrents = [allTorrents objectsAtIndexes:newAddIndexes];
                    for (NSInteger i = newTorrents.count - 1; i >= 0; i--)
                    {
                        [self.fDisplayedTorrents insertObject:newTorrents[i] atIndex:0];
                        [self.fTableView insertItemsAtIndexes:[NSIndexSet indexSetWithIndex:0] inParent:nil
                                                withAnimation:NSTableViewAnimationSlideLeft];
                    }
                }

                [self.fDisplayedTorrents insertObjects:[allTorrents objectsAtIndexes:addIndexes] atIndexes:addIndexes];
                [self.fTableView insertItemsAtIndexes:addIndexes inParent:nil withAnimation:NSTableViewAnimationSlideDown];
            }
        }
    }
    else if (groupRows && wasGroupRows)
    {
        beganUpdates = YES;
        [self.fTableView beginUpdates];

        NSMutableIndexSet* unusedAllTorrentsIndexes = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, allTorrents.count)];

        NSMutableDictionary* groupsByIndex = [NSMutableDictionary dictionaryWithCapacity:self.fDisplayedTorrents.count];
        for (TorrentGroup* group in self.fDisplayedTorrents)
        {
            groupsByIndex[@(group.groupIndex)] = group;
        }

        NSUInteger const originalGroupCount = self.fDisplayedTorrents.count;
        for (NSUInteger index = 0; index < originalGroupCount; ++index)
        {
            TorrentGroup* group = self.fDisplayedTorrents[index];

            NSMutableIndexSet* removeIndexes = [NSMutableIndexSet indexSet];

            for (NSUInteger indexInGroup = 0; indexInGroup < group.torrents.count; ++indexInGroup)
            {
                Torrent* torrent = group.torrents[indexInGroup];
                NSUInteger const allIndex = [allTorrents indexOfObjectAtIndexes:unusedAllTorrentsIndexes options:NSEnumerationConcurrent
                                                                    passingTest:^BOOL(Torrent* obj, NSUInteger /*idx*/, BOOL* /*stop*/) {
                                                                        return obj == torrent;
                                                                    }];
                if (allIndex == NSNotFound)
                {
                    [removeIndexes addIndex:indexInGroup];
                }
                else
                {
                    BOOL markTorrentAsUsed = YES;

                    NSInteger const groupValue = torrent.groupValue;
                    if (groupValue != group.groupIndex)
                    {
                        TorrentGroup* newGroup = groupsByIndex[@(groupValue)];
                        if (!newGroup)
                        {
                            newGroup = [[TorrentGroup alloc] initWithGroup:groupValue];
                            groupsByIndex[@(groupValue)] = newGroup;
                            [self.fDisplayedTorrents addObject:newGroup];

                            [self.fTableView insertItemsAtIndexes:[NSIndexSet indexSetWithIndex:self.fDisplayedTorrents.count - 1]
                                                         inParent:nil
                                                    withAnimation:NSTableViewAnimationEffectFade];
                            [self.fTableView isGroupCollapsed:groupValue] ? [self.fTableView collapseItem:newGroup] :
                                                                            [self.fTableView expandItem:newGroup];
                        }
                        else
                        {
                            if ([self.fDisplayedTorrents indexOfObject:newGroup
                                                               inRange:NSMakeRange(index + 1, originalGroupCount - (index + 1))] != NSNotFound)
                            {
                                markTorrentAsUsed = NO;
                            }
                        }

                        [group.torrents removeObjectAtIndex:indexInGroup];
                        [newGroup.torrents addObject:torrent];

                        [self.fTableView moveItemAtIndex:indexInGroup inParent:group toIndex:newGroup.torrents.count - 1
                                                inParent:newGroup];

                        --indexInGroup;
                    }

                    if (markTorrentAsUsed)
                    {
                        [unusedAllTorrentsIndexes removeIndex:allIndex];
                    }
                }
            }

            if (removeIndexes.count > 0)
            {
                [group.torrents removeObjectsAtIndexes:removeIndexes];
                [self.fTableView removeItemsAtIndexes:removeIndexes inParent:group withAnimation:NSTableViewAnimationEffectFade];
            }
        }

        [unusedAllTorrentsIndexes enumerateIndexesUsingBlock:^(NSUInteger allIndex, BOOL* /*stop*/) {
            Torrent* torrent = allTorrents[allIndex];
            NSInteger const groupValue = torrent.groupValue;
            TorrentGroup* group = groupsByIndex[@(groupValue)];
            if (!group)
            {
                group = [[TorrentGroup alloc] initWithGroup:groupValue];
                groupsByIndex[@(groupValue)] = group;
                [self.fDisplayedTorrents addObject:group];

                [self.fTableView insertItemsAtIndexes:[NSIndexSet indexSetWithIndex:self.fDisplayedTorrents.count - 1] inParent:nil
                                        withAnimation:NSTableViewAnimationEffectFade];
                [self.fTableView isGroupCollapsed:groupValue] ? [self.fTableView collapseItem:group] : [self.fTableView expandItem:group];
            }

            BOOL const newTorrent = [self.fAddingTransfers containsObject:torrent];
            NSUInteger insertIndex;

            if (newTorrent)
            {
                insertIndex = 0;
            }
            else
            {
                insertIndex = [group.torrents indexOfObjectPassingTest:^BOOL(Torrent* existing, NSUInteger /*idx*/, BOOL* stop) {
                    NSUInteger existingIndex = [allTorrents indexOfObject:existing];
                    if (existingIndex != NSNotFound && existingIndex > allIndex)
                    {
                        *stop = YES;
                        return YES;
                    }
                    return NO;
                }];
                if (insertIndex == NSNotFound)
                {
                    insertIndex = group.torrents.count;
                }
            }
            [group.torrents insertObject:torrent atIndex:insertIndex];

            [self.fTableView insertItemsAtIndexes:[NSIndexSet indexSetWithIndex:insertIndex] inParent:group
                                    withAnimation:newTorrent ? NSTableViewAnimationSlideLeft : NSTableViewAnimationSlideDown];
        }];

        NSIndexSet* removeGroupIndexes = [self.fDisplayedTorrents
            indexesOfObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, originalGroupCount)]
                              options:NSEnumerationConcurrent passingTest:^BOOL(id obj, NSUInteger /*idx*/, BOOL* /*stop*/) {
                                  return ((TorrentGroup*)obj).torrents.count == 0;
                              }];

        if (removeGroupIndexes.count > 0)
        {
            [self.fDisplayedTorrents removeObjectsAtIndexes:removeGroupIndexes];
            [self.fTableView removeItemsAtIndexes:removeGroupIndexes inParent:nil withAnimation:NSTableViewAnimationEffectFade];
        }

        NSSortDescriptor* groupDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"groupOrderValue" ascending:YES];
        [self rearrangeTorrentTableArray:self.fDisplayedTorrents forParent:nil withSortDescriptors:@[ groupDescriptor ]
                        beganTableUpdate:&beganUpdates];
    }
    else
    {
        [self.fTableView removeAllCollapsedGroups];

        NSArray<Torrent*>* selectedTorrents = self.fTableView.selectedTorrents;

        beganUpdates = YES;
        [self.fTableView beginUpdates];

        [self.fTableView removeItemsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.fDisplayedTorrents.count)]
                                     inParent:nil
                                withAnimation:NSTableViewAnimationSlideDown];

        if (groupRows)
        {
            NSMutableDictionary* groupsByIndex = [NSMutableDictionary dictionaryWithCapacity:GroupsController.groups.numberOfGroups];
            for (Torrent* torrent in allTorrents)
            {
                NSInteger const groupValue = torrent.groupValue;
                TorrentGroup* group = groupsByIndex[@(groupValue)];
                if (!group)
                {
                    group = [[TorrentGroup alloc] initWithGroup:groupValue];
                    groupsByIndex[@(groupValue)] = group;
                }

                [group.torrents addObject:torrent];
            }

            [self.fDisplayedTorrents setArray:groupsByIndex.allValues];

            NSSortDescriptor* groupDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"groupOrderValue" ascending:YES];
            [self.fDisplayedTorrents sortUsingDescriptors:@[ groupDescriptor ]];
        }
        else
            [self.fDisplayedTorrents setArray:allTorrents];

        [self.fTableView insertItemsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.fDisplayedTorrents.count)]
                                     inParent:nil
                                withAnimation:NSTableViewAnimationEffectFade];

        if (groupRows)
        {
            for (TorrentGroup* group in self.fDisplayedTorrents)
                [self.fTableView expandItem:group];
        }

        self.fTableView.selectedTorrents = selectedTorrents;
    }

    BOOL skipSorting = self.fAddingTransfers && self.fAddingTransfers.count > 0;
    if (!skipSorting)
    {
        [self sortTorrentsCallUpdates:!beganUpdates includeQueueOrder:YES];
    }

    if (beganUpdates)
    {
        [self.fTableView endUpdates];
    }
    [NSAnimationContext endGrouping];

    BOOL const skipFullReload = [self shouldSkipFullTableReloadForListChangeWithAddingCount:self.fAddingTransfers.count
                                                                                skipSorting:skipSorting
                                                                                  groupRows:groupRows
                                                                               wasGroupRows:wasGroupRows
                                                                 didIncrementalTableUpdates:beganUpdates];
    [self refreshTransfersTableAfterListChange:groupRows filterActive:(filterStatus || filterGroup || (searchStrings != nil))
                            reloadTableContent:!skipFullReload];
}

- (BOOL)shouldSkipFullTableReloadForListChangeWithAddingCount:(NSUInteger)addingCount
                                                  skipSorting:(BOOL)skipSorting
                                                    groupRows:(BOOL)groupRows
                                                 wasGroupRows:(BOOL)wasGroupRows
                                   didIncrementalTableUpdates:(BOOL)didIncrementalUpdates
{
    return (groupRows == wasGroupRows && addingCount > 0 && skipSorting) || didIncrementalUpdates;
}

- (void)reloadTransfersTableContent
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.fTableView reloadData];
    [CATransaction commit];
}

- (void)refreshTransfersTableAfterListChange:(BOOL)groupRows
                                filterActive:(BOOL)filterActive
                          reloadTableContent:(BOOL)reloadTableContent
{
    if (reloadTableContent)
        [self reloadTransfersTableContent];

    [self resetInfo];
    [self setBottomCountText:groupRows || filterActive];
    [self setWindowSizeToFit];
    [self scrollToFirstNewTransferIfNeeded];
}

- (void)selectAndScrollToTorrent:(Torrent*)torrent
{
    if (!torrent)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger row = [self.fTableView rowForItem:torrent];
        if (row == -1 && [self.fDefaults boolForKey:@"SortByGroup"])
        {
            __block TorrentGroup* parent = nil;
            [self.fDisplayedTorrents enumerateObjectsWithOptions:NSEnumerationConcurrent
                                                      usingBlock:^(TorrentGroup* group, NSUInteger /*idx*/, BOOL* stop) {
                                                          if ([group.torrents containsObject:torrent])
                                                          {
                                                              parent = group;
                                                              *stop = YES;
                                                          }
                                                      }];
            if (parent)
            {
                [self.fTableView expandItem:parent];
                row = [self.fTableView rowForItem:torrent];
            }
        }
        if (row >= 0 && row < self.fTableView.numberOfRows)
            [self.fTableView selectAndScrollToRow:row];
    });
}

- (void)scrollToFirstNewTransferIfNeeded
{
    if (self.fAddingTransfers.count == 0)
        return;
    Torrent* firstNew = self.fAddingTransfers.anyObject;
    self.fAddingTransfers = nil;
    [self selectAndScrollToTorrent:firstNew];
}

@end
#pragma clang diagnostic pop
