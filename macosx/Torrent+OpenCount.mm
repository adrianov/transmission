// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "FileListNode.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static NSString* const kOpenCountsUserDefaultsKey = @"TransmissionOpenCounts";

static NSMutableDictionary<NSString*, NSNumber*>* openCountsDictionary(void)
{
    NSDictionary* stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:kOpenCountsUserDefaultsKey];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void saveOpenCounts(NSDictionary<NSString*, NSNumber*>* counts)
{
    [NSUserDefaults.standardUserDefaults setObject:counts forKey:kOpenCountsUserDefaultsKey];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (OpenCount)

- (NSString*)openCountKeyForFileNode:(FileListNode*)node
{
    NSString* hash = self.hashString;
    if (node.isFolder)
    {
        NSString* relPath = node.path.length > 0 ? [node.path stringByAppendingPathComponent:node.name] : node.name;
        return [NSString stringWithFormat:@"%@|d%@", hash, relPath];
    }
    return [NSString stringWithFormat:@"%@|f%lu", hash, (unsigned long)node.indexes.firstIndex];
}

- (NSString*)openCountKeyForPlayableItem:(NSDictionary*)item
{
    NSString* folder = item[@"folder"];
    NSNumber* indexNum = item[@"index"];
    NSUInteger index = indexNum ? indexNum.unsignedIntegerValue : NSNotFound;
    if (folder.length > 0)
        return [NSString stringWithFormat:@"%@|d%@", self.hashString, folder];
    return [NSString stringWithFormat:@"%@|f%lu", self.hashString, (unsigned long)index];
}

- (void)recordOpenForFileNode:(FileListNode*)node
{
    NSString* key = [self openCountKeyForFileNode:node];
    NSMutableDictionary* counts = openCountsDictionary();
    NSUInteger n = [(NSNumber*)counts[key] unsignedIntegerValue];
    counts[key] = @(n + 1);
    saveOpenCounts(counts);
}

- (void)recordOpenForPlayableItem:(NSDictionary*)item
{
    NSString* key = [self openCountKeyForPlayableItem:item];
    NSMutableDictionary* counts = openCountsDictionary();
    NSUInteger n = [(NSNumber*)counts[key] unsignedIntegerValue];
    counts[key] = @(n + 1);
    saveOpenCounts(counts);
}

- (NSUInteger)openCountForFileNode:(FileListNode*)node
{
    NSString* key = [self openCountKeyForFileNode:node];
    return [(NSNumber*)openCountsDictionary()[key] unsignedIntegerValue];
}

- (NSString*)openCountLabelForFileNode:(FileListNode*)node
{
    NSUInteger n = [self openCountForFileNode:node];
    if (n == 0)
        return nil;
    NSString* category = node.isFolder ? nil : [self mediaCategoryForFile:node.indexes.firstIndex];
    BOOL isPlayed = [category isEqualToString:@"video"] || [category isEqualToString:@"adult"] || [category isEqualToString:@"audio"];
    NSString* format = isPlayed ? NSLocalizedString(@"Played: %lu", "Files tab -> open count for video/audio") :
                                  NSLocalizedString(@"Opened: %lu", "Files tab -> open count for other");
    return [NSString stringWithFormat:format, (unsigned long)n];
}

- (NSString*)openCountLabelForPlayableItem:(NSDictionary*)item
{
    NSString* key = [self openCountKeyForPlayableItem:item];
    NSUInteger n = [(NSNumber*)openCountsDictionary()[key] unsignedIntegerValue];
    if (n == 0)
        return nil;
    NSString* category = item[@"category"] ?: @"";
    BOOL isPlayed = [category isEqualToString:@"video"] || [category isEqualToString:@"adult"] || [category isEqualToString:@"audio"];
    NSString* format = isPlayed ? NSLocalizedString(@"Played: %lu", "Play button tooltip -> open count for video/audio") :
                                  NSLocalizedString(@"Opened: %lu", "Play button tooltip -> open count for other");
    return [NSString stringWithFormat:format, (unsigned long)n];
}

@end
#pragma clang diagnostic pop
