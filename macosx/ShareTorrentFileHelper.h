// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.
// Created by Mitchell Livingston on 1/10/14.

#import <AppKit/AppKit.h>

@interface ShareTorrentFileHelper : NSObject

@property(nonatomic, class, readonly) ShareTorrentFileHelper* sharedHelper;

/// Loads ShareKit once so menu/toolbar share UI does not dlopen ShareKit. Until this completes,
/// menuItems returns nothing while a modal dialog is open to avoid AppKit hangs.
+ (void)preloadSharingFrameworkIfNeeded;

@property(nonatomic, readonly) NSArray<NSURL*>* shareTorrentURLs;
@property(nonatomic, readonly) NSArray<NSMenuItem*>* menuItems;

@end
