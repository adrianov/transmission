// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

@interface NSString (PrivateHumanizedTitle)
- (NSString* _Nonnull)tr_formatHumanTitle;
- (NSString* _Nonnull)tr_formatHumanFileName;
- (nullable NSString*)tr_formatHumanEpisodeName;
- (nullable NSString*)tr_formatHumanEpisodeTitleWithTorrentName:(NSString* _Nullable)torrentName;
@end
