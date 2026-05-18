// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <Foundation/Foundation.h>

@class Torrent;

NSTimeInterval videoDurationForPath(NSString* path);
BOOL videoDisplayAllowedForItem(Torrent* torrent, NSDictionary* entry, CGFloat progress, BOOL visible);
