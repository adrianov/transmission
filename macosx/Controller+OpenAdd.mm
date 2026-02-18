// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Opening and adding torrents: files, magnets, URL sheet, pasteboard. Keeps add-flow logic out of main Controller.

@import UniformTypeIdentifiers;

#include <libtransmission/transmission.h>
#include <libtransmission/torrent-metainfo.h>

#import "Controller.h"
#import "ControllerPrivate.h"
#import "ControllerConstants.h"
#import "AddMagnetWindowController.h"
#import "AddWindowController.h"
#import "GroupsController.h"
#import "Torrent.h"
#import "URLSheetWindowController.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (OpenAdd)

- (void)openFiles:(NSArray<NSString*>*)filenames addType:(AddType)type forcePath:(NSString*)path
{
    BOOL deleteTorrentFile, canToggleDelete = NO;
    switch (type)
    {
    case AddTypeCreated:
        deleteTorrentFile = NO;
        break;
    case AddTypeURL:
        deleteTorrentFile = YES;
        break;
    default:
        deleteTorrentFile = [self.fDefaults boolForKey:@"DeleteOriginalTorrent"];
        canToggleDelete = YES;
    }

    for (NSString* torrentPath in filenames)
    {
        auto metainfo = tr_torrent_metainfo{};
        if (!metainfo.parse_torrent_file(torrentPath.UTF8String))
        {
            if (type != AddTypeAuto)
            {
                [self invalidOpenAlert:torrentPath.lastPathComponent];
            }
            continue;
        }

        auto foundTorrent = tr_torrentFindFromMetainfo(self.fLib, &metainfo);
        if (foundTorrent != nullptr)
        {
            if (tr_torrentHasMetadata(foundTorrent))
            {
                [self duplicateOpenAlert:@(metainfo.name().c_str())];
            }
            else if (!tr_torrentSetMetainfoFromFile(foundTorrent, &metainfo, torrentPath.UTF8String))
            {
                [self duplicateOpenAlert:@(metainfo.name().c_str())];
            }
            continue;
        }

        NSString* location;
        BOOL lockDestination = NO;
        if (path)
        {
            location = path.stringByExpandingTildeInPath;
            lockDestination = YES;
        }
        else if ([self.fDefaults boolForKey:@"DownloadLocationConstant"])
        {
            location = [self.fDefaults stringForKey:@"DownloadFolder"].stringByExpandingTildeInPath;
        }
        else if (type != AddTypeURL)
        {
            location = torrentPath.stringByDeletingLastPathComponent;
        }
        else
        {
            location = nil;
        }

        auto const is_multifile = metainfo.file_count() > 1;
        BOOL const showWindow = type == AddTypeShowOptions ||
            ([self.fDefaults boolForKey:@"DownloadAsk"] && (is_multifile || ![self.fDefaults boolForKey:@"DownloadAskMulti"]) &&
             (type != AddTypeAuto || ![self.fDefaults boolForKey:@"DownloadAskManual"]));

        Torrent* torrent;
        if (!(torrent = [[Torrent alloc] initWithPath:torrentPath location:location
                                    deleteTorrentFile:showWindow ? NO : deleteTorrentFile
                                                  lib:self.fLib]))
        {
            continue;
        }

        if (!lockDestination && [GroupsController.groups usesCustomDownloadLocationForIndex:torrent.groupValue])
        {
            location = [GroupsController.groups customDownloadLocationForIndex:torrent.groupValue];
            [torrent changeDownloadFolderBeforeUsing:location determinationType:TorrentDeterminationAutomatic];
        }

        if (type == AddTypeCreated)
        {
            [torrent resetCache];
        }

        if (showWindow || !location)
        {
            AddWindowController* addController = [[AddWindowController alloc] initWithTorrent:torrent destination:location
                                                                              lockDestination:lockDestination
                                                                                   controller:self
                                                                                  torrentFile:torrentPath
                                                            deleteTorrentCheckEnableInitially:deleteTorrentFile
                                                                              canToggleDelete:canToggleDelete];
            [addController showWindow:self];

            if (!self.fAddWindows)
            {
                self.fAddWindows = [[NSMutableSet alloc] init];
            }
            [self.fAddWindows addObject:addController];
        }
        else
        {
            if (type != AddTypeCreated && torrent.haveVerified > 0 && !torrent.allDownloaded)
            {
                [torrent resetCache];
            }

            [torrent update];
            [self insertTorrentAtTop:torrent];

            if (!self.fAddingTransfers)
            {
                self.fAddingTransfers = [[NSMutableSet alloc] init];
            }
            [self.fAddingTransfers addObject:torrent];

            if ([self.fDefaults boolForKey:@"AutoStartDownload"])
            {
                [torrent startTransfer];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleTorrentPausedForDiskSpace:torrent];
            });
        }
    }

    [self fullUpdateUI];
}

- (void)askOpenConfirmed:(AddWindowController*)addController add:(BOOL)add
{
    Torrent* torrent = addController.torrent;

    if (add)
    {
        [torrent update];
        [self insertTorrentAtTop:torrent];

        if (!self.fAddingTransfers)
        {
            self.fAddingTransfers = [[NSMutableSet alloc] init];
        }
        [self.fAddingTransfers addObject:torrent];

        [self fullUpdateUI];
    }
    else
    {
        [torrent closeRemoveTorrent:NO];
    }

    [self.fAddWindows removeObject:addController];
    if (self.fAddWindows.count == 0)
    {
        self.fAddWindows = nil;
    }
}

- (void)openMagnet:(NSString*)address
{
    tr_torrent* duplicateTorrent;
    if ((duplicateTorrent = tr_torrentFindFromMagnetLink(self.fLib, address.UTF8String)))
    {
        NSString* name = @(tr_torrentName(duplicateTorrent));
        [self duplicateOpenMagnetAlert:address transferName:name];
        return;
    }

    NSString* location = nil;
    if ([self.fDefaults boolForKey:@"DownloadLocationConstant"])
    {
        location = [self.fDefaults stringForKey:@"DownloadFolder"].stringByExpandingTildeInPath;
    }

    Torrent* torrent;
    if (!(torrent = [[Torrent alloc] initWithMagnetAddress:address location:location lib:self.fLib]))
    {
        [self invalidOpenMagnetAlert:address];
        return;
    }

    if ([GroupsController.groups usesCustomDownloadLocationForIndex:torrent.groupValue])
    {
        location = [GroupsController.groups customDownloadLocationForIndex:torrent.groupValue];
        [torrent changeDownloadFolderBeforeUsing:location determinationType:TorrentDeterminationAutomatic];
    }

    if ([self.fDefaults boolForKey:@"MagnetOpenAsk"] || !location)
    {
        AddMagnetWindowController* addController = [[AddMagnetWindowController alloc] initWithTorrent:torrent destination:location
                                                                                           controller:self];
        [addController showWindow:self];

        if (!self.fAddWindows)
        {
            self.fAddWindows = [[NSMutableSet alloc] init];
        }
        [self.fAddWindows addObject:addController];
    }
    else
    {
        if ([self.fDefaults boolForKey:@"AutoStartDownload"])
        {
            [torrent startTransfer];
        }

        [torrent update];
        [self insertTorrentAtTop:torrent];

        if (!self.fAddingTransfers)
        {
            self.fAddingTransfers = [[NSMutableSet alloc] init];
        }
        [self.fAddingTransfers addObject:torrent];
    }

    [self fullUpdateUI];
}

- (void)askOpenMagnetConfirmed:(AddMagnetWindowController*)addController add:(BOOL)add
{
    Torrent* torrent = addController.torrent;

    if (add)
    {
        [torrent update];
        [self insertTorrentAtTop:torrent];

        if (!self.fAddingTransfers)
        {
            self.fAddingTransfers = [[NSMutableSet alloc] init];
        }
        [self.fAddingTransfers addObject:torrent];

        [self fullUpdateUI];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleTorrentPausedForDiskSpace:torrent];
        });
    }
    else
    {
        [torrent closeRemoveTorrent:NO];
    }

    [self.fAddWindows removeObject:addController];
    if (self.fAddWindows.count == 0)
    {
        self.fAddWindows = nil;
    }
}

- (void)openCreatedFile:(NSNotification*)notification
{
    NSDictionary* dict = notification.userInfo;
    [self openFiles:@[ dict[@"File"] ] addType:AddTypeCreated forcePath:dict[@"Path"]];
}

- (void)openFilesWithDict:(NSDictionary*)dictionary
{
    [self openFiles:dictionary[@"Filenames"] addType:static_cast<AddType>([dictionary[@"AddType"] intValue]) forcePath:nil];
}

- (void)open:(NSArray*)files
{
    NSDictionary* dict = @{ @"Filenames" : files, @"AddType" : @(AddTypeManual) };
    [self performSelectorOnMainThread:@selector(openFilesWithDict:) withObject:dict waitUntilDone:NO];
}

- (void)openShowSheet:(id)sender
{
    NSOpenPanel* panel = [NSOpenPanel openPanel];

    panel.allowsMultipleSelection = YES;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;

    UTType* torrentType = [UTType typeWithIdentifier:@"org.bittorrent.torrent"];
    panel.allowedContentTypes = torrentType ? @[ torrentType, UTTypeData ] : @[ UTTypeData ];

    [panel beginSheetModalForWindow:self.fWindow completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK)
        {
            NSMutableArray* filenames = [NSMutableArray arrayWithCapacity:panel.URLs.count];
            for (NSURL* url in panel.URLs)
            {
                [filenames addObject:url.path];
            }

            NSDictionary* dictionary = @{
                @"Filenames" : filenames,
                @"AddType" : sender == self.fOpenIgnoreDownloadFolder ? @(AddTypeShowOptions) : @(AddTypeManual)
            };
            [self performSelectorOnMainThread:@selector(openFilesWithDict:) withObject:dictionary waitUntilDone:NO];
        }
    }];
}

- (void)invalidOpenAlert:(NSString*)filename
{
    if (![self.fDefaults boolForKey:@"WarningInvalidOpen"])
    {
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString
        stringWithFormat:NSLocalizedString(@"\"%@\" is not a valid torrent file.", "Open invalid alert -> title"), filename];
    alert.informativeText = NSLocalizedString(@"The torrent file cannot be opened because it contains invalid data.", "Open invalid alert -> message");

    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "Open invalid alert -> button")];

    [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn)
    {
        [self.fDefaults setBool:NO forKey:@"WarningInvalidOpen"];
    }
}

- (void)invalidOpenMagnetAlert:(NSString*)address
{
    if (![self.fDefaults boolForKey:@"WarningInvalidOpen"])
    {
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Adding magnetized transfer failed.", "Magnet link failed -> title");
    alert.informativeText = [NSString stringWithFormat:NSLocalizedString(
                                                           @"There was an error when adding the magnet link \"%@\"."
                                                            " The transfer will not occur.",
                                                           "Magnet link failed -> message"),
                                                       address];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "Magnet link failed -> button")];

    [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn)
    {
        [self.fDefaults setBool:NO forKey:@"WarningInvalidOpen"];
    }
}

- (void)duplicateOpenAlert:(NSString*)name
{
    if (![self.fDefaults boolForKey:@"WarningDuplicate"])
    {
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString
        stringWithFormat:NSLocalizedString(@"A transfer of \"%@\" already exists.", "Open duplicate alert -> title"), name];
    alert.informativeText = NSLocalizedString(
        @"The transfer cannot be added because it is a duplicate of an already existing transfer.",
        "Open duplicate alert -> message");

    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "Open duplicate alert -> button")];
    alert.showsSuppressionButton = YES;

    [alert runModal];
    if (alert.suppressionButton.state)
    {
        [self.fDefaults setBool:NO forKey:@"WarningDuplicate"];
    }
}

- (void)duplicateOpenMagnetAlert:(NSString*)address transferName:(NSString*)name
{
    if (![self.fDefaults boolForKey:@"WarningDuplicate"])
    {
        return;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    if (name)
    {
        alert.messageText = [NSString
            stringWithFormat:NSLocalizedString(@"A transfer of \"%@\" already exists.", "Open duplicate magnet alert -> title"), name];
    }
    else
    {
        alert.messageText = NSLocalizedString(@"Magnet link is a duplicate of an existing transfer.", "Open duplicate magnet alert -> title");
    }
    alert.informativeText = [NSString
        stringWithFormat:NSLocalizedString(
                             @"The magnet link  \"%@\" cannot be added because it is a duplicate of an already existing transfer.",
                             "Open duplicate magnet alert -> message"),
                         address];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "Open duplicate magnet alert -> button")];
    alert.showsSuppressionButton = YES;

    [alert runModal];
    if (alert.suppressionButton.state)
    {
        [self.fDefaults setBool:NO forKey:@"WarningDuplicate"];
    }
}

- (void)openURL:(NSString*)urlString
{
    if ([urlString rangeOfString:@"magnet:" options:(NSAnchoredSearch | NSCaseInsensitiveSearch)].location != NSNotFound)
    {
        [self openMagnet:urlString];
    }
    else
    {
        if ([urlString rangeOfString:@"://"].location == NSNotFound)
        {
            if ([urlString rangeOfString:@"."].location == NSNotFound)
            {
                NSInteger beforeCom;
                if ((beforeCom = [urlString rangeOfString:@"/"].location) != NSNotFound)
                {
                    urlString = [NSString stringWithFormat:@"http://www.%@.com/%@",
                                                           [urlString substringToIndex:beforeCom],
                                                           [urlString substringFromIndex:beforeCom + 1]];
                }
                else
                {
                    urlString = [NSString stringWithFormat:@"http://www.%@.com/", urlString];
                }
            }
            else
            {
                urlString = [@"http://" stringByAppendingString:urlString];
            }
        }

        NSURL* url = [NSURL URLWithString:urlString];
        if (url == nil)
        {
            NSLog(@"Detected non-URL string \"%@\". Ignoring.", urlString);
            return;
        }

        [self.fSession getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask*>* _Nonnull tasks) {
            for (NSURLSessionTask* task in tasks)
            {
                if ([task.originalRequest.URL isEqual:url])
                {
                    NSLog(@"Already downloading %@", url);
                    return;
                }
            }
            NSURLSessionDataTask* download = [self.fSession dataTaskWithURL:url];
            [download resume];
        }];
    }
}

- (void)openURLShowSheet:(id)sender
{
    if (!self.fUrlSheetController)
    {
        self.fUrlSheetController = [[URLSheetWindowController alloc] init];

        [self.fWindow beginSheet:self.fUrlSheetController.window completionHandler:^(NSModalResponse returnCode) {
            if (returnCode == 1)
            {
                NSString* urlString = self.fUrlSheetController.urlString;
                urlString = [urlString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self openURL:urlString];
                });
            }
            self.fUrlSheetController = nil;
        }];
    }
}

- (void)openPasteboard
{
    NSArray<NSURL*>* arrayOfURLs = [NSPasteboard.generalPasteboard readObjectsForClasses:@[ [NSURL class] ] options:nil];

    if (arrayOfURLs.count > 0)
    {
        for (NSURL* url in arrayOfURLs)
        {
            [self openURL:url.absoluteString];
        }
        return;
    }

    NSArray<NSString*>* arrayOfStrings = [NSPasteboard.generalPasteboard readObjectsForClasses:@[ [NSString class] ] options:nil];
    if (arrayOfStrings.count == 0)
    {
        return;
    }
    NSDataDetector* linkDetector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    NSRegularExpression* magnetDetector = [NSRegularExpression regularExpressionWithPattern:@"magnet:?([^\\p{Z}\\v])+" options:kNilOptions
                                                                                      error:nil];
    for (NSString* itemString in arrayOfStrings)
    {
        for (NSTextCheckingResult* result in [linkDetector matchesInString:itemString options:0
                                                                     range:NSMakeRange(0, itemString.length)])
        {
            [self openURL:result.URL.absoluteString];
        }

        for (NSTextCheckingResult* result in [magnetDetector matchesInString:itemString options:0
                                                                       range:NSMakeRange(0, itemString.length)])
        {
            [self openURL:[itemString substringWithRange:result.range]];
        }
    }
}

@end
#pragma clang diagnostic pop
