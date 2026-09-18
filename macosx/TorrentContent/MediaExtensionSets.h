// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#pragma once

#import <Foundation/Foundation.h>

extern NSSet<NSString*>* sVideoExtensions;
extern NSSet<NSString*>* sAudioExtensions;
extern NSSet<NSString*>* sBookExtensions;
extern NSSet<NSString*>* sSoftwareExtensions;

/// Initializes the extension sets on first use (idempotent).
void ensureMediaExtensionSets(void);
