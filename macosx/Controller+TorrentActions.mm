// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Torrent actions: move data, copy torrent/magnet, reveal, rename, announce, verify. Keeps action handlers out of main Controller.

@import UniformTypeIdentifiers;

#import "ControllerPrivate.h"
#import "FileRenameSheetController.h"
#import "Torrent.h"
#import "TorrentTableView.h"

@implementation Controller (TorrentActions)

- (void)moveDataFilesSelected:(id)sender
{
    [self moveDataFiles:self.fTableView.selectedTorrents];
}

- (void)moveDataFiles:(NSArray<Torrent*>*)torrents
{
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.prompt = NSLocalizedString(@"Select", "Move torrent -> prompt");
    panel.allowsMultipleSelection = NO;
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;

    NSUInteger count = torrents.count;
    if (count == 1)
    {
        panel.message = [NSString
            stringWithFormat:NSLocalizedString(@"Select the new folder for \"%@\".", "Move torrent -> select destination folder"),
                             torrents[0].name];
    }
    else
    {
        panel.message = [NSString
            localizedStringWithFormat:NSLocalizedString(@"Select the new folder for %lu data files.", "Move torrent -> select destination folder"),
                                      count];
    }

    [panel beginSheetModalForWindow:self.fWindow completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK)
        {
            for (Torrent* torrent in torrents)
            {
                [torrent moveTorrentDataFileTo:panel.URLs[0].path];
            }
        }
    }];
}

- (void)copyTorrentFiles:(id)sender
{
    [self copyTorrentFileForTorrents:[[NSMutableArray alloc] initWithArray:self.fTableView.selectedTorrents]];
}

- (void)copyTorrentFileForTorrents:(NSMutableArray<Torrent*>*)torrents
{
    if (torrents.count == 0)
    {
        return;
    }

    Torrent* torrent = torrents[0];

    if (!torrent.magnet && [NSFileManager.defaultManager fileExistsAtPath:torrent.torrentLocation])
    {
        NSSavePanel* panel = [NSSavePanel savePanel];
        UTType* torrentType = [UTType typeWithIdentifier:@"org.bittorrent.torrent"];
        panel.allowedContentTypes = torrentType ? @[ torrentType, UTTypeData ] : @[ UTTypeData ];
        panel.extensionHidden = NO;

        panel.nameFieldStringValue = torrent.name;

        [panel beginSheetModalForWindow:self.fWindow completionHandler:^(NSInteger result) {
            if (result == NSModalResponseOK)
            {
                [torrent copyTorrentFileTo:panel.URL.path];
            }

            [torrents removeObjectAtIndex:0];
            [self performSelectorOnMainThread:@selector(copyTorrentFileForTorrents:) withObject:torrents waitUntilDone:NO];
        }];
    }
    else
    {
        if (!torrent.magnet)
        {
            NSAlert* alert = [[NSAlert alloc] init];
            [alert addButtonWithTitle:NSLocalizedString(@"OK", "Torrent file copy alert -> button")];
            alert.messageText = [NSString
                stringWithFormat:NSLocalizedString(@"Copy of \"%@\" Cannot Be Created", "Torrent file copy alert -> title"),
                                 torrent.name];
            alert.informativeText = [NSString
                stringWithFormat:NSLocalizedString(@"The torrent file (%@) cannot be found.", "Torrent file copy alert -> message"),
                                 torrent.torrentLocation];
            alert.alertStyle = NSAlertStyleWarning;

            [alert runModal];
        }

        [torrents removeObjectAtIndex:0];
        [self copyTorrentFileForTorrents:torrents];
    }
}

- (void)copyMagnetLinks:(id)sender
{
    [self.fTableView copy:sender];
}

- (void)revealFile:(id)sender
{
    NSArray* selected = self.fTableView.selectedTorrents;
    NSMutableArray* paths = [NSMutableArray arrayWithCapacity:selected.count];
    for (Torrent* torrent in selected)
    {
        NSString* location = torrent.dataLocation;
        if (location)
        {
            [paths addObject:[NSURL fileURLWithPath:location]];
        }
    }

    if (paths.count > 0)
    {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:paths];
    }
}

- (IBAction)renameSelected:(id)sender
{
    NSArray* selected = self.fTableView.selectedTorrents;
    NSAssert(selected.count == 1, @"1 transfer needs to be selected to rename, but %ld are selected", selected.count);
    Torrent* torrent = selected[0];

    [FileRenameSheetController presentSheetForTorrent:torrent modalForWindow:self.fWindow completionHandler:^(BOOL didRename) {
        if (didRename)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self fullUpdateUI];

                [NSNotificationCenter.defaultCenter postNotificationName:@"ResetInspector" object:self
                                                                userInfo:@{ @"Torrent" : torrent }];
            });
        }
    }];
}

- (void)announceSelectedTorrents:(id)sender
{
    for (Torrent* torrent in self.fTableView.selectedTorrents)
    {
        if (torrent.canManualAnnounce)
        {
            [torrent manualAnnounce];
        }
    }
}

- (void)verifySelectedTorrents:(id)sender
{
    [self verifyTorrents:self.fTableView.selectedTorrents];
}

- (void)verifyTorrents:(NSArray<Torrent*>*)torrents
{
    for (Torrent* torrent in torrents)
    {
        [torrent resetCache];
    }

    [self applyFilter];
}

- (NSArray<Torrent*>*)selectedTorrents
{
    return self.fTableView.selectedTorrents;
}

@end
