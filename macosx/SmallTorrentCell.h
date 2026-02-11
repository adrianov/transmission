// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCell.h"

@interface SmallTorrentCell : TorrentCell
/// YES when the mouse is over the icon area (used for action button vs icon in compact row).
@property(nonatomic) BOOL fIconHover;
@end
