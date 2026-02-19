// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Private API for Controller and its categories. Not for external use.

#import <AppKit/AppKit.h>
#import <Quartz/Quartz.h>
#import <UserNotifications/UserNotifications.h>

#include <libtransmission/transmission.h>

#import "Controller.h"

@class Badger;
@class DragOverlayWindow;
@class FilterBarController;
@class InfoWindowController;
@class MessageWindowController;
@class StatusBarController;
@class Torrent;
@class TorrentGroup;
@class TorrentTableView;
@class URLSheetWindowController;

#import "PowerManager.h"

@interface Controller ()<UNUserNotificationCenterDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate, PowerManagerDelegate>

@property(nonatomic) IBOutlet NSWindow* fWindow;
@property(nonatomic) NSLayoutConstraint* fMinHeightConstraint;
@property(nonatomic) NSLayoutConstraint* fFixedHeightConstraint;
@property(nonatomic) IBOutlet TorrentTableView* fTableView;

@property(nonatomic) IBOutlet NSMenuItem* fOpenIgnoreDownloadFolder;
@property(nonatomic) IBOutlet NSButton* fActionButton;
@property(nonatomic) IBOutlet NSButton* fSpeedLimitButton;
@property(nonatomic) IBOutlet NSButton* fClearCompletedButton;
@property(nonatomic) IBOutlet NSTextField* fTotalTorrentsField;
@property(nonatomic) IBOutlet NSMenuItem* fNextFilterItem;

@property(nonatomic) IBOutlet NSMenuItem* fNextInfoTabItem;
@property(nonatomic) IBOutlet NSMenuItem* fPrevInfoTabItem;

@property(nonatomic) IBOutlet NSMenu* fSortMenu;

@property(nonatomic) IBOutlet NSMenu* fGroupsSetMenu;
@property(nonatomic) IBOutlet NSMenu* fGroupsSetContextMenu;

@property(nonatomic) IBOutlet NSMenu* fShareMenu;
@property(nonatomic) IBOutlet NSMenu* fShareContextMenu;

@property(nonatomic, readonly) tr_session* fLib;

@property(nonatomic, readonly) NSMutableArray<Torrent*>* fTorrents;
@property(nonatomic, readonly) NSMutableArray* fDisplayedTorrents;
@property(nonatomic, readonly) NSMutableDictionary<NSString*, Torrent*>* fTorrentHashes;

@property(nonatomic, readonly) InfoWindowController* fInfoController;
@property(nonatomic) MessageWindowController* fMessageController;

@property(nonatomic, readonly) NSUserDefaults* fDefaults;

@property(nonatomic, readonly) NSString* fConfigDirectory;

@property(nonatomic) DragOverlayWindow* fOverlayWindow;

@property(nonatomic) NSTimer* fTimer;

@property(nonatomic) StatusBarController* fStatusBar;

@property(nonatomic) FilterBarController* fFilterBar;
@property(nonatomic) NSSearchField* fToolbarSearchField;
@property(nonatomic) BOOL fSyncingSearchFields;

@property(nonatomic) QLPreviewPanel* fPreviewPanel;
@property(nonatomic) BOOL fQuitting;
@property(nonatomic) BOOL fQuitRequested;
@property(nonatomic, readonly) BOOL fPauseOnLaunch;

@property(nonatomic) Badger* fBadger;

@property(nonatomic) NSMutableArray<NSString*>* fAutoImportedNames;
@property(nonatomic) NSTimer* fAutoImportTimer;

@property(nonatomic) NSURLSession* fSession;

@property(nonatomic) NSMutableSet<Torrent*>* fAddingTransfers;

@property(nonatomic) NSMutableSet<NSWindowController*>* fAddWindows;
@property(nonatomic) URLSheetWindowController* fUrlSheetController;

@property(nonatomic) BOOL fGlobalPopoverShown;
@property(nonatomic) NSView* fPositioningView;
@property(nonatomic) BOOL fSoundPlaying;
@property(nonatomic) BOOL fWindowMiniaturized;
@property(nonatomic) NSTimer* fLowPriorityTimer;
@property(nonatomic) BOOL fUsingBackgroundPriority;
@property(nonatomic) BOOL fUpdatingUI;

- (void)insertTorrentAtTop:(Torrent*)torrent;
- (void)refreshVisibleTransferRows;
- (void)reloadTransfersTableContent;
- (void)selectAndScrollToTorrent:(Torrent*)torrent;
- (void)updateSearchPlaceholder;
- (void)preloadSearchFieldTextInput;
- (void)updateSearchFieldClearButtonVisibility:(NSSearchField*)field;

@end
