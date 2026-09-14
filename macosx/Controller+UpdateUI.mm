// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Periodic UI refresh (speed timer): updateUI, fullUpdateUI, setBottomCountText, refreshVisibleTransferRows.
// Keeps button/progress updates responsive when the heavy update is skipped (e.g. regression fix: refresh visible rows on skip).

#import "ControllerPrivate.h"
#import "Badger.h"
#import "InfoWindowController.h"
#import "PowerManager.h"
#import "StatusBarController.h"
#import "Torrent.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
/// Aggregated per-tick stats for the UI refresh.
typedef struct
{
    CGFloat dlRate;
    CGFloat ulRate;
    BOOL anyCompleted;
    BOOL anyActive;
} UIRefreshStats;

static UIRefreshStats UIRefreshStatsForTorrents(NSArray<Torrent*>* torrents)
{
    UIRefreshStats stats = {};
    for (Torrent* torrent in torrents)
    {
        stats.dlRate += torrent.downloadRate;
        stats.ulRate += torrent.uploadRate;
        stats.anyCompleted |= torrent.finishedSeeding;
        stats.anyActive |= torrent.active && !torrent.stalled && !torrent.error;
    }
    return stats;
}

@implementation Controller (UpdateUI)

- (void)updateUI
{
    // Skip heavy update if previous one still in progress; defer row refresh so window restore/close stay responsive
    if (self.fUpdatingUI)
    {
        if (self.fWindow.visible && !NSApp.hidden)
        {
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf refreshVisibleTransferRows];
            });
        }
        return;
    }
    self.fUpdatingUI = YES;

    // Capture torrents array for background processing
    NSArray<Torrent*>* torrents = [self.fTorrents copy];

    // Move the potentially blocking libtransmission calls to a background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // This call may block waiting for session locks - now it won't freeze the UI
        [Torrent updateTorrents:torrents];

        // On file access (local) error, try candidate download dirs and switch location if data found elsewhere
        [self relocateErroredTorrentsIfAccessible:torrents];

        UIRefreshStats stats = UIRefreshStatsForTorrents(torrents);

        // Update UI on main thread; defer row refresh to next run loop so restore/close are responsive
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyUIUpdateWithStats:stats];
            self.fUpdatingUI = NO;
        });
    });
}

/// Applies the refreshed stats to the UI. Runs on the main thread.
- (void)applyUIUpdateWithStats:(UIRefreshStats)stats
{
    PowerManager.shared.shouldPreventSleep = stats.anyActive && [self.fDefaults boolForKey:@"SleepPrevent"];

    if (!NSApp.hidden)
    {
        if (self.fWindow.visible)
        {
            [self sortTorrentsAndIncludeQueueOrder:NO];

            [self.fStatusBar updateWithDownload:stats.dlRate upload:stats.ulRate];

            self.fClearCompletedButton.hidden = !stats.anyCompleted;
        }

        if (self.fInfoController.window.visible)
        {
            [self.fInfoController updateInfoStats];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshVisibleTransferRows];
        });
    }

    [self updateSearchPlaceholder];

    [self.fBadger updateBadgeWithDownload:stats.dlRate upload:stats.ulRate];
}

- (void)fullUpdateUI
{
    [self updateUI];
    [self applyFilter];
    [self.fWindow.toolbar validateVisibleItems];
    [self updateTorrentHistory];
}

- (void)setBottomCountText:(BOOL)filtering
{
    NSString* totalTorrentsString;
    NSUInteger totalCount = self.fTorrents.count;
    if (totalCount != 1)
    {
        totalTorrentsString = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu transfers", "Status bar transfer count"), totalCount];
    }
    else
    {
        totalTorrentsString = NSLocalizedString(@"1 transfer", "Status bar transfer count");
    }

    if (filtering)
    {
        NSUInteger count = self.fTableView.numberOfRows; //have to factor in collapsed rows
        if (count > 0 && ![self.fDisplayedTorrents[0] isKindOfClass:[Torrent class]])
        {
            count -= self.fDisplayedTorrents.count;
        }

        totalTorrentsString = [NSString stringWithFormat:NSLocalizedString(@"%@ of %@", "Status bar transfer count"),
                                                         [NSString localizedStringWithFormat:@"%lu", count],
                                                         totalTorrentsString];
    }

    self.fTotalTorrentsField.stringValue = totalTorrentsString;
}

/// Refreshes visible transfer rows (status, progress) from the UI timer. Does not re-request row views to avoid flow view flicker.
- (void)refreshVisibleTransferRows
{
    [self.fTableView updateVisibleRowsContent];
}

@end
#pragma clang diagnostic pop
