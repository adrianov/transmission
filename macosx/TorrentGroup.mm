// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>
#include <libtransmission/utils.h> // tr_getRatio()

#import "TorrentGroup.h"
#import "GroupsController.h"
#import "Torrent.h"

@implementation TorrentGroup

- (instancetype)initWithGroup:(NSInteger)group
{
    if ((self = [super init]))
    {
        _groupIndex = group;
        _torrents = [[NSMutableArray alloc] init];
        _cacheValid = NO;
    }
    return self;
}

- (void)invalidateCache
{
    _cacheValid = NO;
}

- (void)updateCache
{
    uint64_t uploaded = 0, total_size = 0;
    CGFloat rate = 0.0;
    CGFloat downloadRate = 0.0;

    for (Torrent* torrent in self.torrents)
    {
        uploaded += torrent.uploadedTotal;
        total_size += torrent.totalSizeSelected;
        rate += torrent.uploadRate;
        downloadRate += torrent.downloadRate;
    }

    self.cachedRatio = tr_getRatio(uploaded, total_size);
    self.cachedUploadRate = rate;
    self.cachedDownloadRate = downloadRate;
    self.cacheValid = YES;
}

- (NSString*)description
{
    return [NSString stringWithFormat:@"Torrent Group %ld: %@", self.groupIndex, self.torrents];
}

- (NSInteger)groupOrderValue
{
    return [GroupsController.groups rowValueForIndex:self.groupIndex];
}

- (CGFloat)ratio
{
    if (!self.cacheValid)
    {
        [self updateCache];
    }
    return self.cachedRatio;
}

- (CGFloat)uploadRate
{
    if (!self.cacheValid)
    {
        [self updateCache];
    }
    return self.cachedUploadRate;
}

- (CGFloat)downloadRate
{
    if (!self.cacheValid)
    {
        [self updateCache];
    }
    return self.cachedDownloadRate;
}

@end
