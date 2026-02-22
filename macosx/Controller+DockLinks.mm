// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Dock menu and About/help link actions.

#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "Torrent.h"

@implementation Controller (DockLinks)

- (NSMenu*)applicationDockMenu:(NSApplication*)sender
{
    if (self.fQuitting)
    {
        return nil;
    }

    NSUInteger seeding = 0, downloading = 0;
    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.seeding)
        {
            seeding++;
        }
        else if (torrent.active)
        {
            downloading++;
        }
    }

    NSMenu* menu = [[NSMenu alloc] init];

    if (seeding > 0)
    {
        NSString* title = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu Seeding", "Dock item - Seeding"), seeding];
        [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    }

    if (downloading > 0)
    {
        NSString* title = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu Downloading", "Dock item - Downloading"), downloading];
        [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    }

    if (seeding > 0 || downloading > 0)
    {
        [menu addItem:[NSMenuItem separatorItem]];
    }

    [menu addItemWithTitle:NSLocalizedString(@"Pause All", "Dock item") action:@selector(stopAllTorrents:) keyEquivalent:@""];
    [menu addItemWithTitle:NSLocalizedString(@"Resume All", "Dock item") action:@selector(resumeAllTorrents:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"Speed Limit", "Dock item") action:@selector(toggleSpeedLimit:) keyEquivalent:@""];

    return menu;
}

- (void)linkHomepage:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kWebsiteURL]];
}

- (void)linkForums:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kForumURL]];
}

- (void)linkGitHub:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kGithubURL]];
}

- (void)linkDonate:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kDonateURL]];
}

@end
