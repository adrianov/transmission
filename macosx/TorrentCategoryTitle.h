// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <Foundation/Foundation.h>

/// Infers media category from a torrent display name when metadata is unavailable (magnet links).
/// Returns @"video", @"audio", @"books", @"software", @"adult", or nil.
FOUNDATION_EXPORT NSString* _Nullable TorrentMediaCategoryFromTitle(NSString* _Nullable title);
