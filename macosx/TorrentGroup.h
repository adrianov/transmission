// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

@class Torrent;

@interface TorrentGroup : NSObject

- (instancetype)initWithGroup:(NSInteger)group;

@property(nonatomic, readonly) NSInteger groupIndex;
@property(nonatomic, readonly) NSInteger groupOrderValue;
@property(nonatomic, readonly) NSMutableArray<Torrent*>* torrents;

@property(nonatomic, readonly) CGFloat ratio;
@property(nonatomic, readonly) CGFloat uploadRate;
@property(nonatomic, readonly) CGFloat downloadRate;

/// Cached values to avoid recalculating on every draw
@property(nonatomic) CGFloat cachedRatio;
@property(nonatomic) CGFloat cachedUploadRate;
@property(nonatomic) CGFloat cachedDownloadRate;
@property(nonatomic) BOOL cacheValid;

- (void)invalidateCache;

@end
