// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>
#import "TorrentTableView.h"

@interface TorrentCell : NSTableCellView

@property(nonatomic) IBOutlet NSButton* fActionButton;
@property(nonatomic) IBOutlet NSButton* fControlButton;
@property(nonatomic) IBOutlet NSButton* fRevealButton;
@property(nonatomic) IBOutlet NSButton* fURLButton;

@property(nonatomic) IBOutlet NSImageView* fIconView;
@property(nonatomic) IBOutlet NSTextField* fIconSubtitleField;
@property(nonatomic) IBOutlet NSImageView* fGroupIndicatorView;

@property(nonatomic) IBOutlet NSStackView* fStackView;
@property(nonatomic) IBOutlet NSTextField* fTorrentTitleField;
@property(nonatomic) IBOutlet NSImageView* fTorrentPriorityView;
@property(nonatomic) IBOutlet NSLayoutConstraint* fTorrentPriorityViewWidthConstraint;

@property(nonatomic) IBOutlet NSTextField* fTorrentProgressField;
@property(nonatomic) IBOutlet NSTextField* fTorrentStatusField;

@property(nonatomic) IBOutlet NSView* fTorrentProgressBarView;

/// Container view for dynamically created play buttons. Created programmatically.
@property(nonatomic) NSView* fPlayButtonsView;
/// Height constraint for the play buttons view (updated dynamically)
@property(nonatomic) NSLayoutConstraint* fPlayButtonsHeightConstraint;
/// Tracks which playable files array was used to create the buttons (for cache invalidation)
@property(nonatomic, weak) NSArray* fPlayButtonsSourceFiles;
/// Tracks the torrent hash to detect when cell is reused for a different torrent
@property(nonatomic, copy) NSString* fTorrentHash;

@property(nonatomic) TorrentTableView* fTorrentTableView;

@end
