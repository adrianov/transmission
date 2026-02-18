// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// NSOutlineView data source and drag for transfers table. Keeps outline view delegate logic out of main Controller.

#import "ControllerPrivate.h"
#import "ControllerConstants.h"
#import "NSMutableArrayAdditions.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"

@implementation Controller (OutlineView)

- (NSInteger)outlineView:(NSOutlineView*)outlineView numberOfChildrenOfItem:(id)item
{
    if (item)
    {
        return ((TorrentGroup*)item).torrents.count;
    }
    else
    {
        return self.fDisplayedTorrents.count;
    }
}

- (id)outlineView:(NSOutlineView*)outlineView child:(NSInteger)index ofItem:(id)item
{
    if (item)
    {
        return ((TorrentGroup*)item).torrents[index];
    }
    else
    {
        return self.fDisplayedTorrents[index];
    }
}

- (BOOL)outlineView:(NSOutlineView*)outlineView isItemExpandable:(id)item
{
    return ![item isKindOfClass:[Torrent class]];
}

- (BOOL)outlineView:(NSOutlineView*)outlineView writeItems:(NSArray*)items toPasteboard:(NSPasteboard*)pasteboard
{
    if ([self.fDefaults boolForKey:@"SortByGroup"] || [[self.fDefaults stringForKey:@"Sort"] isEqualToString:SortTypeOrder])
    {
        NSMutableIndexSet* indexSet = [NSMutableIndexSet indexSet];
        for (id torrent in items)
        {
            if (![torrent isKindOfClass:[Torrent class]])
            {
                return NO;
            }

            [indexSet addIndex:[self.fTableView rowForItem:torrent]];
        }

        [pasteboard declareTypes:@[ kTorrentTableViewDataType ] owner:self];
        [pasteboard setData:[NSKeyedArchiver archivedDataWithRootObject:indexSet requiringSecureCoding:YES error:nil]
                    forType:kTorrentTableViewDataType];
        return YES;
    }
    return NO;
}

- (NSDragOperation)outlineView:(NSOutlineView*)outlineView
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index
{
    NSPasteboard* pasteboard = info.draggingPasteboard;
    if ([pasteboard.types containsObject:kTorrentTableViewDataType])
    {
        if ([self.fDefaults boolForKey:@"SortByGroup"])
        {
            if (!item)
            {
                return NSDragOperationNone;
            }

            if ([[self.fDefaults stringForKey:@"Sort"] isEqualToString:SortTypeOrder])
            {
                if ([item isKindOfClass:[Torrent class]])
                {
                    TorrentGroup* group = [self.fTableView parentForItem:item];
                    index = [group.torrents indexOfObject:item] + 1;
                    item = group;
                }
            }
            else
            {
                if ([item isKindOfClass:[Torrent class]])
                {
                    item = [self.fTableView parentForItem:item];
                }
                index = NSOutlineViewDropOnItemIndex;
            }
        }
        else
        {
            if (index == NSOutlineViewDropOnItemIndex)
            {
                return NSDragOperationNone;
            }

            if (item)
            {
                index = [self.fTableView rowForItem:item] + 1;
                item = nil;
            }
        }

        [self.fTableView setDropItem:item dropChildIndex:index];
        return NSDragOperationGeneric;
    }

    return NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView*)outlineView acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)newRow
{
    NSPasteboard* pasteboard = info.draggingPasteboard;
    if ([pasteboard.types containsObject:kTorrentTableViewDataType])
    {
        NSIndexSet* indexes = [NSKeyedUnarchiver unarchivedObjectOfClass:NSIndexSet.class fromData:[pasteboard dataForType:kTorrentTableViewDataType]
                                                                   error:nil];

        NSMutableArray* movingTorrents = [NSMutableArray arrayWithCapacity:indexes.count];
        for (NSUInteger i = indexes.firstIndex; i != NSNotFound; i = [indexes indexGreaterThanIndex:i])
        {
            Torrent* torrent = [self.fTableView itemAtRow:i];
            [movingTorrents addObject:torrent];
        }

        if (item)
        {
            TorrentGroup* group = (TorrentGroup*)item;
            NSInteger const groupIndex = group.groupIndex;

            for (Torrent* torrent in movingTorrents)
            {
                [torrent setGroupValue:groupIndex determinationType:TorrentDeterminationUserSpecified];
            }
        }

        if (newRow != NSOutlineViewDropOnItemIndex)
        {
            TorrentGroup* group = (TorrentGroup*)item;
            NSArray* groupTorrents = group ? group.torrents : self.fDisplayedTorrents;
            Torrent* topTorrent = nil;
            for (NSInteger i = newRow - 1; i >= 0; i--)
            {
                Torrent* tempTorrent = groupTorrents[i];
                if (![movingTorrents containsObject:tempTorrent])
                {
                    topTorrent = tempTorrent;
                    break;
                }
            }

            [self.fTorrents removeObjectsInArray:movingTorrents];

            NSUInteger const insertIndex = topTorrent ? [self.fTorrents indexOfObject:topTorrent] + 1 : 0;
            NSIndexSet* insertIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertIndex, movingTorrents.count)];
            [self.fTorrents insertObjects:movingTorrents atIndexes:insertIndexes];

            NSUInteger i = 0;
            for (Torrent* torrent in self.fTorrents)
            {
                torrent.queuePosition = i++;
            }

            [Torrent updateTorrents:self.fTorrents];

            [self.fTableView beginUpdates];

            NSUInteger insertDisplayIndex = topTorrent ? [groupTorrents indexOfObject:topTorrent] + 1 : 0;

            for (Torrent* torrent in movingTorrents)
            {
                TorrentGroup* oldParent = item ? [self.fTableView parentForItem:torrent] : nil;
                NSMutableArray* oldTorrents = oldParent ? oldParent.torrents : self.fDisplayedTorrents;
                NSUInteger const oldIndex = [oldTorrents indexOfObject:torrent];

                if (item == oldParent)
                {
                    if (oldIndex < insertDisplayIndex)
                    {
                        --insertDisplayIndex;
                    }
                    [oldTorrents moveObjectAtIndex:oldIndex toIndex:insertDisplayIndex];
                }
                else
                {
                    NSAssert(item && oldParent, @"Expected to be dragging between group rows");

                    NSMutableArray* newTorrents = ((TorrentGroup*)item).torrents;
                    [newTorrents insertObject:torrent atIndex:insertDisplayIndex];
                    [oldTorrents removeObjectAtIndex:oldIndex];
                }

                [self.fTableView moveItemAtIndex:oldIndex inParent:oldParent toIndex:insertDisplayIndex inParent:item];

                ++insertDisplayIndex;
            }

            [self.fTableView endUpdates];
        }

        [self applyFilter];
    }

    return YES;
}

@end
