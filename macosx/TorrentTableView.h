// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

@class Torrent;

extern CGFloat const kGroupSeparatorHeight;

@interface TorrentTableView : NSOutlineView<NSOutlineViewDelegate, NSAnimationDelegate, NSPopoverDelegate, NSMenuItemValidation, NSMenuDelegate>

/// Updates status/progress/hover for visible torrent cells without re-requesting row views (no flow view reconfig).
- (void)updateVisibleRowsContent;

/// Refreshes row heights and content button containers when View > Content Buttons is toggled. Call after changing the preference.
- (void)refreshContentButtonsVisibility;

/// Schedules content button config for visible rows that still need it. Call when scroll ends to fix empty flow view after scroll.
- (void)ensureContentButtonsForVisibleRows;

- (BOOL)isGroupCollapsed:(NSInteger)value;
- (void)removeCollapsedGroup:(NSInteger)value;
- (void)removeAllCollapsedGroups;
- (void)saveCollapsedGroups;

@property(nonatomic) NSArray<Torrent*>* selectedTorrents;

- (NSRect)iconRectForRow:(NSInteger)row;

- (void)copy:(id)sender;
- (void)paste:(id)sender;

- (void)hoverEventBeganForView:(id)view;
- (void)hoverEventEndedForView:(id)view;

- (void)toggleGroupRowRatio;

- (IBAction)toggleControlForTorrent:(id)sender;
- (IBAction)openCommentURL:(id)sender;

- (IBAction)displayTorrentActionPopover:(id)sender;

- (void)togglePiecesBar;
@property(nonatomic, readonly) CGFloat piecesBarPercent;

- (void)selectAndScrollToRow:(NSInteger)row;

@end
