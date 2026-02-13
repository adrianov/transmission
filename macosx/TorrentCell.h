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

/// Container view for play buttons. From XIB in full view; nil in minimal view.
@property(nonatomic) IBOutlet NSView* fPlayButtonsView;
/// Height constraint for the play buttons view (updated dynamically)
@property(nonatomic) IBOutlet NSLayoutConstraint* fPlayButtonsHeightConstraint;
/// Tracks which playable files array was used to create the buttons (for cache invalidation)
@property(nonatomic, weak) NSArray* fPlayButtonsSourceFiles;
/// Tracks the torrent hash to detect when cell is reused for a different torrent
@property(nonatomic, copy) NSString* fTorrentHash;

@property(nonatomic) TorrentTableView* fTorrentTableView;

@property(nonatomic) NSTrackingArea* fHoverTrackingArea;
@property(nonatomic) NSTrackingArea* fHoverButtonsTrackingArea;

/// Cached progress bar image to avoid redrawing during scroll
@property(nonatomic) NSImage* fCachedProgressBarImage;
/// Cached progress value for cache invalidation
@property(nonatomic) CGFloat fCachedProgress;
/// Cached active state for cache invalidation
@property(nonatomic) BOOL fCachedActive;
/// Cached checking state for cache invalidation
@property(nonatomic) BOOL fCachedChecking;
/// Cached pieces bar percent for cache invalidation
@property(nonatomic) CGFloat fCachedPiecesPercent;
/// Cached bar size for cache invalidation
@property(nonatomic) NSSize fCachedBarSize;
- (void)invalidateProgressBarCache;

@end
