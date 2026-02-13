// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Private API for TorrentTableView and its categories (Flow, PlayMenu). Not for external use.

#import "FlowLayoutView.h"
#import "PlayButton.h"
#import "TorrentTableView.h"
#import "TorrentCell.h"

@class Controller;
@class Torrent;

@interface TorrentTableView ()

@property(nonatomic) IBOutlet Controller* fController;
@property(nonatomic, readonly) NSUserDefaults* fDefaults;
@property(nonatomic, readonly) NSMutableIndexSet* fCollapsedGroups;
@property(nonatomic) IBOutlet NSMenu* fContextRow;
@property(nonatomic) IBOutlet NSMenu* fContextNoRow;
@property(nonatomic) NSIndexSet* fSelectedRowIndexes;
@property(nonatomic) CGFloat piecesBarPercent;
@property(nonatomic) NSAnimation* fPiecesBarAnimation;
@property(nonatomic) BOOL fActionPopoverShown;
@property(nonatomic) NSView* fPositioningView;
@property(nonatomic) NSDictionary* fHoverEventDict;
@property(nonatomic) CGFloat fLastKnownWidth;
@property(nonatomic) BOOL fSmallView;
@property(nonatomic) BOOL fSortByGroup;
@property(nonatomic) BOOL fDisplaySmallStatusRegular;
@property(nonatomic) BOOL fDisplayGroupRowRatio;
@property(nonatomic, readonly) NSCache<NSString*, NSImage*>* fIconCache;
@property(nonatomic, readonly) NSMapTable<Torrent*, NSMenu*>* fPlayMenuCache;
@property(nonatomic, readonly) NSMutableArray<PlayButton*>* fPlayButtonPool;
@property(nonatomic, readonly) NSMutableArray<NSTextField*>* fHeaderPool;
@property(nonatomic, readonly) NSMutableIndexSet* fPendingHeightRows;
@property(nonatomic, weak) id fScrollViewPreviousDelegate;

- (BOOL)showContentButtonsPref;
- (NSString*)folderForPlayButton:(NSButton*)sender torrent:(Torrent*)torrent;

@end

@interface TorrentTableView (Flow)
- (BOOL)cellNeedsContentButtonsConfigForCell:(TorrentCell*)cell torrent:(Torrent*)torrent;
- (void)configurePlayButtonsForCell:(TorrentCell*)cell torrent:(Torrent*)torrent;
- (void)refreshPlayButtonStateForCell:(TorrentCell*)cell torrent:(Torrent*)torrent;
- (void)recycleFlowViewForCellReuse:(TorrentCell*)cell;
- (void)recycleSubviewsFromFlowView:(FlowLayoutView*)flowView;
- (void)updatePlayButtonProgressForCell:(TorrentCell*)cell torrent:(Torrent*)torrent;
- (void)noteHeightUpdateForRow:(NSInteger)row;
- (NSMutableArray<NSMutableDictionary*>*)playButtonStateForTorrent:(Torrent*)torrent;
- (NSArray<NSDictionary*>*)playButtonLayoutForTorrent:(Torrent*)torrent state:(NSArray<NSDictionary*>*)state;
@end

@interface TorrentTableView (PlayMenu)
- (NSImage*)iconForPlayableFileItem:(NSDictionary*)fileItem torrent:(Torrent*)torrent;
- (NSString*)menuTitleForPlayableItem:(NSDictionary*)item torrent:(Torrent*)torrent includeProgress:(BOOL)includeProgress;
- (NSMenu*)playMenuForTorrent:(Torrent*)torrent;
- (void)updatePlayMenuForItem:(id)item;
@end
