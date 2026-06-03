// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Dock menu, About/help link actions, and deferred donate alert.

#include <libtransmission/transmission.h>

#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "NSStringAdditions.h"
#import "Torrent.h"

static NSTimeInterval const kDonateNagTime = 60 * 60 * 24 * 7;

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

@implementation Controller (DockLinksPrivate)

- (void)showDonateAlertIfNeeded
{
    if (![self.fDefaults boolForKey:@"WarningDonate"])
    {
        return;
    }

    BOOL const firstLaunch = tr_sessionGetCumulativeStats(self.fLib).sessionCount <= 1;

    NSDate* lastDonateDate = [self.fDefaults objectForKey:@"DonateAskDate"];
    BOOL const timePassed = !lastDonateDate || (-1 * lastDonateDate.timeIntervalSinceNow) >= kDonateNagTime;

    if (firstLaunch || !timePassed)
    {
        return;
    }

    [self.fDefaults setObject:[NSDate date] forKey:@"DonateAskDate"];

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Support open-source indie software", "Donation beg -> title");

    NSString* donateMessage = [NSString
        stringWithFormat:@"%@\n\n%@",
                         NSLocalizedString(@"Transmission is a full-featured torrent application."
                                            " A lot of time and effort have gone into development, coding, and refinement."
                                            " If you enjoy using it, please consider showing your love with a donation.",
                                           "Donation beg -> message"),
                         NSLocalizedString(@"Donate or not, there will be no difference to your torrenting experience.", "Donation beg -> message")];

    alert.informativeText = donateMessage;
    alert.alertStyle = NSAlertStyleInformational;

    [alert addButtonWithTitle:[NSLocalizedString(@"Donate", "Donation beg -> button") stringByAppendingEllipsis]];
    NSButton* noDonateButton = [alert addButtonWithTitle:NSLocalizedString(@"Nope", "Donation beg -> button")];
    noDonateButton.keyEquivalent = @"\e"; //escape key

    BOOL const allowNeverAgain = lastDonateDate != nil;
    alert.showsSuppressionButton = allowNeverAgain;
    if (allowNeverAgain)
    {
        alert.suppressionButton.title = NSLocalizedString(@"Don't bug me about this ever again.", "Donation beg -> button");
    }

    NSInteger const donateResult = [alert runModal];
    if (donateResult == NSAlertFirstButtonReturn)
    {
        [self linkDonate:self];
    }

    if (allowNeverAgain)
    {
        [self.fDefaults setBool:(alert.suppressionButton.state != NSControlStateValueOn) forKey:@"WarningDonate"];
    }
}

@end
