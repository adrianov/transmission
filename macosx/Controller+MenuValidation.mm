// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// NSMenuItemValidation: enable/disable and set state/title for menu items.

@import Quartz;

#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "InfoWindowController.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (MenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
    SEL action = menuItem.action;

    if (action == @selector(toggleSpeedLimit:))
    {
        menuItem.state = [self.fDefaults boolForKey:@"SpeedLimit"] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }

    BOOL canUseTable = self.fWindow.keyWindow || menuItem.menu.supermenu != NSApp.mainMenu;

    if (action == @selector(openShowSheet:) || action == @selector(openURLShowSheet:))
        return self.fWindow.attachedSheet == nil;

    if (action == @selector(setSort:))
    {
        SortType sortType;
        switch (menuItem.tag)
        {
        case SortTagOrder:
            sortType = SortTypeOrder;
            break;
        case SortTagDate:
            sortType = SortTypeDate;
            break;
        case SortTagName:
            sortType = SortTypeName;
            break;
        case SortTagProgress:
            sortType = SortTypeProgress;
            break;
        case SortTagState:
            sortType = SortTypeState;
            break;
        case SortTagTracker:
            sortType = SortTypeTracker;
            break;
        case SortTagActivity:
            sortType = SortTypeActivity;
            break;
        case SortTagSize:
            sortType = SortTypeSize;
            break;
        case SortTagETA:
            sortType = SortTypeETA;
            break;
        default:
            NSAssert1(NO, @"Unknown sort tag received: %ld", [menuItem tag]);
            sortType = SortTypeOrder;
        }

        menuItem.state = [sortType isEqualToString:[self.fDefaults stringForKey:@"Sort"]] ? NSControlStateValueOn : NSControlStateValueOff;
        return self.fWindow.visible;
    }

    if (action == @selector(setGroup:))
    {
        BOOL checked = NO;
        NSInteger index = menuItem.tag;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (index == torrent.groupValue)
            {
                checked = YES;
                break;
            }
        }
        menuItem.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
        return canUseTable && self.fTableView.numberOfSelectedRows > 0;
    }

    if (action == @selector(toggleSmallView:))
    {
        menuItem.state = [self.fDefaults boolForKey:@"SmallView"] ? NSControlStateValueOn : NSControlStateValueOff;
        return self.fWindow.visible;
    }

    if (action == @selector(togglePiecesBar:))
    {
        menuItem.state = [self.fDefaults boolForKey:@"PiecesBar"] ? NSControlStateValueOn : NSControlStateValueOff;
        return self.fWindow.visible;
    }

    if (action == @selector(toggleAvailabilityBar:))
    {
        menuItem.state = [self.fDefaults boolForKey:@"DisplayProgressBarAvailable"] ? NSControlStateValueOn : NSControlStateValueOff;
        return self.fWindow.visible;
    }

    if (action == @selector(toggleShowContentButtons:))
    {
        menuItem.state = [self.fDefaults boolForKey:@"ShowContentButtons"] ? NSControlStateValueOn : NSControlStateValueOff;
        return self.fWindow.visible;
    }

    if (action == @selector(showInfo:))
    {
        menuItem.title = NSLocalizedString(@"Show Inspector", "View menu -> Inspector");
        return YES;
    }

    if (action == @selector(setInfoTab:))
        return self.fInfoController.window.visible;

    if (action == @selector(toggleStatusBar:))
    {
        NSString* title = !self.fStatusBar ? NSLocalizedString(@"Show Status Bar", "View menu -> Status Bar") :
                                             NSLocalizedString(@"Hide Status Bar", "View menu -> Status Bar");
        menuItem.title = title;
        return self.fWindow.visible;
    }

    if (action == @selector(toggleFilterBar:))
    {
        NSString* title = !self.fFilterBar ? NSLocalizedString(@"Show Filter Bar", "View menu -> Filter Bar") :
                                             NSLocalizedString(@"Hide Filter Bar", "View menu -> Filter Bar");
        menuItem.title = title;
        return self.fWindow.visible;
    }

    if (action == @selector(toggleToolbarShown:))
    {
        NSString* title = !self.fWindow.toolbar.isVisible ? NSLocalizedString(@"Show Toolbar", "View menu -> Toolbar") :
                                                            NSLocalizedString(@"Hide Toolbar", "View menu -> Toolbar");
        menuItem.title = title;
        return self.fWindow.visible;
    }

    if (action == @selector(switchFilter:))
        return self.fWindow.visible && self.fFilterBar;

    if (action == @selector(revealFile:))
        return canUseTable && self.fTableView.numberOfSelectedRows > 0;

    if (action == @selector(renameSelected:))
        return canUseTable && self.fTableView.numberOfSelectedRows == 1;

    if (action == @selector(removeNoDelete:) || action == @selector(removeDeleteData:))
    {
        BOOL const isSearchFocused = [self.fWindow.firstResponder isKindOfClass:NSTextView.class] &&
            [self.fWindow fieldEditor:NO forObject:nil] != nil &&
            [self.fToolbarSearchField isEqual:((NSTextView*)self.fWindow.firstResponder).delegate];
        if (isSearchFocused)
            return NO;

        BOOL warning = NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (torrent.active && ([self.fDefaults boolForKey:@"CheckRemoveDownloading"] ? !torrent.seeding : YES))
            {
                warning = YES;
                break;
            }
        }

        NSString *title = menuItem.title, *ellipsis = NSString.ellipsis;
        if (warning && [self.fDefaults boolForKey:@"CheckRemove"])
        {
            if (![title hasSuffix:ellipsis])
                menuItem.title = [title stringByAppendingEllipsis];
        }
        else if ([title hasSuffix:ellipsis])
        {
            menuItem.title = [title substringToIndex:[title rangeOfString:ellipsis].location];
        }
        return canUseTable && self.fTableView.numberOfSelectedRows > 0;
    }

    if (action == @selector(clearCompleted:))
    {
        NSString *title = menuItem.title, *ellipsis = NSString.ellipsis;
        if ([self.fDefaults boolForKey:@"WarningRemoveCompleted"])
        {
            if (![title hasSuffix:ellipsis])
                menuItem.title = [title stringByAppendingEllipsis];
        }
        else if ([title hasSuffix:ellipsis])
        {
            menuItem.title = [title substringToIndex:[title rangeOfString:ellipsis].location];
        }
        for (Torrent* torrent in self.fTorrents)
        {
            if (torrent.finishedSeeding)
                return YES;
        }
        return NO;
    }

    if (action == @selector(stopAllTorrents:))
    {
        for (Torrent* torrent in self.fTorrents)
        {
            if (torrent.active || torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if (action == @selector(resumeAllTorrents:))
    {
        for (Torrent* torrent in self.fTorrents)
        {
            if (!torrent.active && !torrent.waitingToStart && !torrent.finishedSeeding)
                return YES;
        }
        return NO;
    }

    if (action == @selector(resumeWaitingTorrents:))
    {
        if (![self.fDefaults boolForKey:@"Queue"] && ![self.fDefaults boolForKey:@"QueueSeed"])
            return NO;
        for (Torrent* torrent in self.fTorrents)
        {
            if (torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if (action == @selector(resumeSelectedTorrentsNoWait:))
    {
        if (!canUseTable)
            return NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (!torrent.active)
                return YES;
        }
        return NO;
    }

    if (action == @selector(stopSelectedTorrents:))
    {
        if (!canUseTable)
            return NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (torrent.active || torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if (action == @selector(resumeSelectedTorrents:))
    {
        if (!canUseTable)
            return NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (!torrent.active && !torrent.waitingToStart)
                return YES;
        }
        return NO;
    }

    if (action == @selector(announceSelectedTorrents:))
    {
        if (!canUseTable)
            return NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (torrent.canManualAnnounce)
                return YES;
        }
        return NO;
    }

    if (action == @selector(verifySelectedTorrents:))
    {
        if (!canUseTable)
            return NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (!torrent.magnet)
                return YES;
        }
        return NO;
    }

    if (action == @selector(moveDataFilesSelected:))
        return canUseTable && self.fTableView.numberOfSelectedRows > 0;

    if (action == @selector(copyTorrentFiles:))
    {
        if (!canUseTable)
            return NO;
        for (Torrent* torrent in self.fTableView.selectedTorrents)
        {
            if (!torrent.magnet)
                return YES;
        }
        return NO;
    }

    if (action == @selector(copyMagnetLinks:))
        return canUseTable && self.fTableView.numberOfSelectedRows > 0;

    if (action == @selector(setSortReverse:))
    {
        BOOL const isReverse = menuItem.tag == SortOrderTagDescending;
        menuItem.state = (isReverse == [self.fDefaults boolForKey:@"SortReverse"]) ? NSControlStateValueOn : NSControlStateValueOff;
        return ![[self.fDefaults stringForKey:@"Sort"] isEqualToString:SortTypeOrder];
    }

    if (action == @selector(setSortByGroup:))
    {
        menuItem.state = [self.fDefaults boolForKey:@"SortByGroup"] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }

    if (action == @selector(toggleQuickLook:))
    {
        BOOL const visible = [QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible;
        NSString* title = !visible ? NSLocalizedString(@"Quick Look", "View menu -> Quick Look") :
                                     NSLocalizedString(@"Close Quick Look", "View menu -> Quick Look");
        menuItem.title = title;
        return self.fTableView.numberOfSelectedRows > 0;
    }

    return YES;
}

@end
#pragma clang diagnostic pop
