// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "Torrent.h"

@implementation TorrentContent

- (void)clearPlayButtonCache
{
    self.cachedPlayButtonState = nil;
    self.cachedPlayButtonStateByIndex = nil;
    self.cachedPlayButtonStateByFolder = nil;
    self.cachedPlayButtonSource = nil;
    self.cachedPlayButtonLayout = nil;
    self.cachedPlayMenuLayout = nil;
    self.cachedPlayButtonProgressGeneration = 0;
}

@end
