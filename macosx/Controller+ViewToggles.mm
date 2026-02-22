// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Main window view toggles: row size, pieces bar, filter bar, status bar, toolbar.

#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "FilterBarController.h"
#import "StatusBarController.h"
#import "TorrentTableView.h"

@implementation Controller (ViewToggles)

- (void)toggleSmallView:(id)sender
{
    BOOL makeSmall = ![self.fDefaults boolForKey:@"SmallView"];
    [self.fDefaults setBool:makeSmall forKey:@"SmallView"];

    self.fTableView.rowHeight = makeSmall ? kRowHeightSmall : kRowHeightRegular;

    [self.fTableView beginUpdates];
    [self.fTableView
        noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.fTableView.numberOfRows)]];
    [self.fTableView endUpdates];

    [self reloadTransfersTableContent];
    [self updateForAutoSize];
}

- (void)togglePiecesBar:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"PiecesBar"] forKey:@"PiecesBar"];
    [self.fTableView togglePiecesBar];
}

- (void)toggleAvailabilityBar:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"DisplayProgressBarAvailable"] forKey:@"DisplayProgressBarAvailable"];
    [self.fTableView display];
}

- (void)toggleShowContentButtons:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"ShowContentButtons"] forKey:@"ShowContentButtons"];
    [self.fTableView refreshContentButtonsVisibility];
    [self refreshVisibleTransferRows];
    [self updateForAutoSize];
}

- (void)toggleStatusBar:(id)sender
{
    BOOL const show = self.fStatusBar == nil || self.fStatusBar.isHidden;
    [self.fDefaults setBool:show forKey:@"StatusBar"];
    [self updateMainWindow];
}

- (void)toggleFilterBar:(id)sender
{
    BOOL const show = self.fFilterBar == nil || self.fFilterBar.isHidden;

    if (!show)
    {
        [self.fFilterBar reset];
    }

    [self.fDefaults setBool:show forKey:@"FilterBar"];
    [self updateMainWindow];

    if (show)
    {
        [self focusFilterField];
    }
}

- (IBAction)toggleToolbarShown:(id)sender
{
    [self.fWindow toggleToolbarShown:sender];
}

@end
