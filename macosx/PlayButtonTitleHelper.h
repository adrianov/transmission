// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <Foundation/Foundation.h>

void playButtonApplyTitleStripping(NSMutableArray<NSMutableDictionary*>* state);
BOOL playButtonIsItemVisible(NSString* type, CGFloat progress, BOOL wanted);
