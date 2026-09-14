// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <Foundation/Foundation.h>

@class Torrent;

/// Per-entry state rules for play buttons: builds fresh entries from playable files and refreshes
/// progress/visibility/title per tick. Pure functions over the entry dictionaries; the caller owns
/// the state array and the torrent.content caches.
void playButtonBuildStateForPlayableFiles(NSMutableArray<NSMutableDictionary*>* state, NSArray<NSDictionary*>* playableFiles, Torrent* torrent);

/// Applies current progress/visibility/title to one entry. Returns whether anything view-visible
/// changed; sets *visibilityChanged when a visible flag flipped (layout-invalidating).
BOOL playButtonRefreshEntry(NSMutableDictionary* entry, Torrent* torrent, BOOL* visibilityChanged);
