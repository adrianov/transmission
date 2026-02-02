// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <algorithm>

#include <libtransmission/transmission.h>

#import "DjvuConverter.h"
#import "Fb2Converter.h"
#import "NSStringAdditions.h"
#import "Torrent.h"
#import "TorrentPrivate.h"

static int const kETAIdleDisplaySec = 2 * 60;
static NSTimeInterval const kDiskSpaceCheckThrottleSeconds = 5.0;

static NSDateComponentsFormatter* etaFormatter()
{
    static NSDateComponentsFormatter* formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateComponentsFormatter new];
        formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleShort;
        formatter.maximumUnitCount = 2;
        formatter.collapsesLargestUnit = YES;
        formatter.includesTimeRemainingPhrase = YES;
    });
    formatter.referenceDate = NSDate.date;
    return formatter;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Torrent (StatusStrings)

- (NSString*)progressString
{
    NSString* string;

    if (self.magnet)
    {
        NSString* progressString = self.fStat->metadataPercentComplete > 0.0 ?
            [NSString stringWithFormat:NSLocalizedString(@"%@ of torrent metadata retrieved", "Torrent -> progress string"),
                                       [NSString percentString:self.fStat->metadataPercentComplete longDecimals:YES]] :
            NSLocalizedString(@"torrent metadata needed", "Torrent -> progress string");
        string = [NSString stringWithFormat:@"%@ — %@", NSLocalizedString(@"Magnetized transfer", "Torrent -> progress string"), progressString];
    }
    else
    {
        if (!self.allDownloaded)
        {
            CGFloat progress;
            if (self.folder && [self.fDefaults boolForKey:@"DisplayStatusProgressSelected"])
            {
                string = [NSString stringForFilePartialSize:self.haveTotal fullSize:self.totalSizeSelected];
                progress = self.progressDone;
            }
            else
            {
                string = [NSString stringForFilePartialSize:self.haveTotal fullSize:self.size];
                progress = self.progress;
            }

            string = [string stringByAppendingFormat:@" (%@)", [NSString percentString:progress longDecimals:YES]];
        }
        else
        {
            NSString* downloadString;
            if (!self.complete)
            {
                if ([self.fDefaults boolForKey:@"DisplayStatusProgressSelected"])
                {
                    downloadString = [NSString stringWithFormat:NSLocalizedString(@"%@ selected", "Torrent -> progress string"),
                                                                [NSString stringForFileSize:self.haveTotal]];
                }
                else
                {
                    downloadString = [NSString stringForFilePartialSize:self.haveTotal fullSize:self.size];
                    downloadString = [downloadString
                        stringByAppendingFormat:@" (%@)", [NSString percentString:self.progress longDecimals:YES]];
                }
            }
            else
            {
                downloadString = [NSString stringForFileSize:self.size];
            }

            NSString* uploadString = [NSString stringWithFormat:NSLocalizedString(@"uploaded %@ (Ratio: %@)", "Torrent -> progress string"),
                                                                [NSString stringForFileSize:self.uploadedTotal],
                                                                [NSString stringForRatio:self.ratio]];

            string = [downloadString stringByAppendingFormat:@", %@", uploadString];
        }

        if (self.shouldShowEta)
        {
            string = [string stringByAppendingFormat:@" — %@", self.etaString];
        }
    }

    return string;
}

- (NSString*)statusString
{
    NSString* failedConversionPath = [DjvuConverter failedConversionPathForTorrent:self];
    if (failedConversionPath)
    {
        NSString* failedConversionFileName = failedConversionPath.lastPathComponent;
        NSString* errorMessage = [DjvuConverter failedConversionErrorForPath:failedConversionPath];
        if (errorMessage.length > 0)
        {
            return [NSString stringWithFormat:NSLocalizedString(@"Error: %@ cannot be converted to PDF (%@)", "Torrent -> status string"),
                                              failedConversionFileName,
                                              errorMessage];
        }
        return [NSString stringWithFormat:NSLocalizedString(@"Error: %@ cannot be converted to PDF", "Torrent -> status string"),
                                          failedConversionFileName];
    }

    NSString* failedFb2FileName = [Fb2Converter failedConversionFileNameForTorrent:self];
    if (failedFb2FileName)
    {
        return [NSString stringWithFormat:NSLocalizedString(@"Error: %@ cannot be converted to EPUB", "Torrent -> status string"),
                                          failedFb2FileName];
    }

    NSString* convertingFileName = [DjvuConverter convertingFileNameForTorrent:self];
    if (convertingFileName)
    {
        [DjvuConverter ensureConversionDispatchedForTorrent:self];
        NSString* progress = [DjvuConverter convertingProgressForTorrent:self];
        if (progress.length > 0)
        {
            return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ (%@) to PDF for compatibility reading…", "Torrent -> status string"),
                                              convertingFileName,
                                              progress];
        }
        return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ to PDF for compatibility reading…", "Torrent -> status string"),
                                          convertingFileName];
    }

    NSString* convertingFb2FileName = [Fb2Converter convertingFileNameForTorrent:self];
    if (convertingFb2FileName)
    {
        [Fb2Converter ensureConversionDispatchedForTorrent:self];
        NSString* progress = [Fb2Converter convertingProgressForTorrent:self];
        if (progress.length > 0)
        {
            return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ (%@) to EPUB for compatibility reading…", "Torrent -> status string"),
                                              convertingFb2FileName,
                                              progress];
        }
        return [NSString stringWithFormat:NSLocalizedString(@"Converting %@ to EPUB for compatibility reading…", "Torrent -> status string"),
                                          convertingFb2FileName];
    }

    NSString* string;

    if (self.anyErrorOrWarning)
    {
        switch (self.fStat->error)
        {
        case TR_STAT_LOCAL_ERROR:
            string = NSLocalizedString(@"Error", "Torrent -> status string");
            break;
        case TR_STAT_TRACKER_ERROR:
            string = NSLocalizedString(@"Tracker returned error", "Torrent -> status string");
            break;
        case TR_STAT_TRACKER_WARNING:
            string = NSLocalizedString(@"Tracker returned warning", "Torrent -> status string");
            break;
        default:
            NSAssert(NO, @"unknown error state");
        }

        NSString* errorString = self.errorMessage;
        if (errorString && ![errorString isEqualToString:@""])
        {
            string = [string stringByAppendingFormat:@": %@", errorString];
        }
    }
    else
    {
        switch (self.fStat->activity)
        {
        case TR_STATUS_STOPPED:
            if (self.finishedSeeding)
            {
                string = NSLocalizedString(@"Seeding complete", "Torrent -> status string");
            }
            else if (self.pausedForDiskSpace)
            {
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - self.fLastDiskSpaceCheckTime > kDiskSpaceCheckThrottleSeconds)
                {
                    [self alertForRemainingDiskSpace];
                    self.fLastDiskSpaceCheckTime = now;
                }

                NSString* usedString = [NSString stringForFileSizeOneDecimal:self.fDiskSpaceUsedByTorrents];
                NSString* neededString = [NSString stringForFileSizeOneDecimal:self.diskSpaceNeeded];
                NSString* availableString = [NSString stringForFileSizeOneDecimal:self.diskSpaceAvailable];
                NSString* totalString = [NSString stringForFileSizeOneDecimal:self.diskSpaceTotal];
                string = [NSString
                    stringWithFormat:NSLocalizedString(@"Not enough disk space. Used for torrents %@, Need %@, Available %@ of %@", "Torrent -> status string"),
                                     usedString,
                                     neededString,
                                     availableString,
                                     totalString];
            }
            else
            {
                string = NSLocalizedString(@"Paused", "Torrent -> status string");
            }
            break;

        case TR_STATUS_DOWNLOAD_WAIT:
            string = [NSLocalizedString(@"Waiting to download", "Torrent -> status string") stringByAppendingEllipsis];
            break;

        case TR_STATUS_SEED_WAIT:
            string = [NSLocalizedString(@"Waiting to seed", "Torrent -> status string") stringByAppendingEllipsis];
            break;

        case TR_STATUS_CHECK_WAIT:
            string = [NSLocalizedString(@"Waiting to check existing data", "Torrent -> status string") stringByAppendingEllipsis];
            break;

        case TR_STATUS_CHECK:
            string = [NSString stringWithFormat:@"%@ (%@)",
                                                NSLocalizedString(@"Checking existing data", "Torrent -> status string"),
                                                [NSString percentString:self.checkingProgress longDecimals:YES]];
            break;

        case TR_STATUS_DOWNLOAD:
            {
                NSUInteger const totalPeersCount = std::max<NSUInteger>(self.totalPeersConnected, self.peersSendingToUs);
                if (totalPeersCount != 1)
                {
                    string = [NSString localizedStringWithFormat:NSLocalizedString(@"Downloading from %lu of %lu peers", "Torrent -> status string"),
                                                                 self.peersSendingToUs,
                                                                 totalPeersCount];
                }
                else
                {
                    string = [NSString stringWithFormat:NSLocalizedString(@"Downloading from %lu of 1 peer", "Torrent -> status string"),
                                                        self.peersSendingToUs];
                }
            }

            if (NSUInteger const webSeedCount = self.fStat->webseedsSendingToUs; webSeedCount > 0)
            {
                NSString* webSeedString;
                if (webSeedCount != 1)
                {
                    webSeedString = [NSString
                        localizedStringWithFormat:NSLocalizedString(@"%lu web seeds", "Torrent -> status string"), webSeedCount];
                }
                else
                {
                    webSeedString = NSLocalizedString(@"web seed", "Torrent -> status string");
                }

                string = [string stringByAppendingFormat:@" + %@", webSeedString];
            }

            break;

        case TR_STATUS_SEED:
            {
                NSUInteger const totalPeersCount = std::max<NSUInteger>(self.totalPeersConnected, self.peersGettingFromUs);
                if (totalPeersCount != 1)
                {
                    string = [NSString localizedStringWithFormat:NSLocalizedString(@"Seeding to %1$lu of %2$lu peers", "Torrent -> status string"),
                                                                 self.peersGettingFromUs,
                                                                 totalPeersCount];
                }
                else
                {
                    string = [NSString localizedStringWithFormat:NSLocalizedString(@"Seeding to %1$lu of %2$lu peer", "Torrent -> status string"),
                                                                 self.peersGettingFromUs,
                                                                 totalPeersCount];
                }
            }
            break;
        }
    }

    return string;
}

- (NSString*)shortStatusString
{
    NSString* string;

    switch (self.fStat->activity)
    {
    case TR_STATUS_STOPPED:
        if (self.finishedSeeding)
        {
            string = NSLocalizedString(@"Seeding complete", "Torrent -> status string");
        }
        else
        {
            string = NSLocalizedString(@"Paused", "Torrent -> status string");
        }
        break;

    case TR_STATUS_DOWNLOAD_WAIT:
        string = [NSLocalizedString(@"Waiting to download", "Torrent -> status string") stringByAppendingEllipsis];
        break;

    case TR_STATUS_SEED_WAIT:
        string = [NSLocalizedString(@"Waiting to seed", "Torrent -> status string") stringByAppendingEllipsis];
        break;

    case TR_STATUS_CHECK_WAIT:
        string = [NSLocalizedString(@"Waiting to check existing data", "Torrent -> status string") stringByAppendingEllipsis];
        break;

    case TR_STATUS_CHECK:
        string = [NSString stringWithFormat:@"%@ (%@)",
                                            NSLocalizedString(@"Checking existing data", "Torrent -> status string"),
                                            [NSString percentString:self.checkingProgress longDecimals:YES]];
        break;

    case TR_STATUS_DOWNLOAD:
        string = [NSString stringWithFormat:@"%@: %@, %@: %@",
                                            NSLocalizedString(@"DL", "Torrent -> status string"),
                                            [NSString stringForSpeed:self.downloadRate],
                                            NSLocalizedString(@"UL", "Torrent -> status string"),
                                            [NSString stringForSpeed:self.uploadRate]];
        break;

    case TR_STATUS_SEED:
        string = [NSString stringWithFormat:@"%@: %@, %@: %@",
                                            NSLocalizedString(@"Ratio", "Torrent -> status string"),
                                            [NSString stringForRatio:self.ratio],
                                            NSLocalizedString(@"UL", "Torrent -> status string"),
                                            [NSString stringForSpeed:self.uploadRate]];
        break;
    }

    if (self.shouldShowEta)
    {
        return self.etaString;
    }
    else
    {
        return string;
    }
}

- (NSString*)remainingTimeString
{
    if (self.shouldShowEta)
    {
        return self.etaString;
    }
    else
    {
        return self.shortStatusString;
    }
}

- (NSString*)stateString
{
    switch (self.fStat->activity)
    {
    case TR_STATUS_STOPPED:
    case TR_STATUS_DOWNLOAD_WAIT:
    case TR_STATUS_SEED_WAIT:
        {
            NSString* string = NSLocalizedString(@"Paused", "Torrent -> status string");

            NSString* extra = nil;
            if (self.waitingToStart)
            {
                extra = self.fStat->activity == TR_STATUS_DOWNLOAD_WAIT ?
                    NSLocalizedString(@"Waiting to download", "Torrent -> status string") :
                    NSLocalizedString(@"Waiting to seed", "Torrent -> status string");
            }
            else if (self.finishedSeeding)
            {
                extra = NSLocalizedString(@"Seeding complete", "Torrent -> status string");
            }

            return extra ? [string stringByAppendingFormat:@" (%@)", extra] : string;
        }

    case TR_STATUS_CHECK_WAIT:
        return [NSLocalizedString(@"Waiting to check existing data", "Torrent -> status string") stringByAppendingEllipsis];

    case TR_STATUS_CHECK:
        return [NSString stringWithFormat:@"%@ (%@)",
                                          NSLocalizedString(@"Checking existing data", "Torrent -> status string"),
                                          [NSString percentString:self.checkingProgress longDecimals:YES]];

    case TR_STATUS_DOWNLOAD:
        return NSLocalizedString(@"Downloading", "Torrent -> status string");

    case TR_STATUS_SEED:
        return NSLocalizedString(@"Seeding", "Torrent -> status string");
    }
}

- (NSUInteger)totalPeersConnected
{
    return self.fStat->peersConnected;
}

- (NSUInteger)totalPeersTracker
{
    return self.fStat->peersFrom[TR_PEER_FROM_TRACKER];
}

- (NSUInteger)totalPeersIncoming
{
    return self.fStat->peersFrom[TR_PEER_FROM_INCOMING];
}

- (NSUInteger)totalPeersCache
{
    return self.fStat->peersFrom[TR_PEER_FROM_RESUME];
}

- (NSUInteger)totalPeersPex
{
    return self.fStat->peersFrom[TR_PEER_FROM_PEX];
}

- (NSUInteger)totalPeersDHT
{
    return self.fStat->peersFrom[TR_PEER_FROM_DHT];
}

- (NSUInteger)totalPeersLocal
{
    return self.fStat->peersFrom[TR_PEER_FROM_LPD];
}

- (NSUInteger)totalPeersLTEP
{
    return self.fStat->peersFrom[TR_PEER_FROM_LTEP];
}

- (NSUInteger)totalKnownPeersTracker
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_TRACKER];
}

- (NSUInteger)totalKnownPeersIncoming
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_INCOMING];
}

- (NSUInteger)totalKnownPeersCache
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_RESUME];
}

- (NSUInteger)totalKnownPeersPex
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_PEX];
}

- (NSUInteger)totalKnownPeersDHT
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_DHT];
}

- (NSUInteger)totalKnownPeersLocal
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_LPD];
}

- (NSUInteger)totalKnownPeersLTEP
{
    return self.fStat->knownPeersFrom[TR_PEER_FROM_LTEP];
}

- (NSUInteger)peersSendingToUs
{
    return self.fStat->peersSendingToUs;
}

- (NSUInteger)peersGettingFromUs
{
    return self.fStat->peersGettingFromUs;
}

- (BOOL)shouldShowEta
{
    if (self.fStat->activity == TR_STATUS_DOWNLOAD)
    {
        return YES;
    }
    else if (self.seeding)
    {
        if (tr_torrentGetSeedRatio(self.fHandle, NULL))
        {
            return YES;
        }

        if (self.fStat->etaIdle != TR_ETA_NOT_AVAIL && self.fStat->etaIdle < kETAIdleDisplaySec)
        {
            return YES;
        }
    }

    return NO;
}

- (NSString*)etaString
{
    time_t eta = self.fStat->eta;
    BOOL fromIdle = NO;
    if (eta < 0)
    {
        eta = self.fStat->etaIdle;
        fromIdle = YES;
    }
    if (eta < 0 || eta > INT32_MAX || (fromIdle && eta >= kETAIdleDisplaySec))
    {
        if (self.downloading && self.downloadRate > 0.0 && self.sizeLeft > 0)
        {
            double const eta_seconds = static_cast<double>(self.sizeLeft) / (self.downloadRate * 1024.0);
            if (eta_seconds > 0.0 && eta_seconds <= INT32_MAX)
            {
                return [etaFormatter() stringFromTimeInterval:eta_seconds];
            }
        }

        return NSLocalizedString(@"remaining time unknown", "Torrent -> eta string");
    }

    NSString* idleString = [etaFormatter() stringFromTimeInterval:eta];

    if (fromIdle)
    {
        idleString = [idleString stringByAppendingFormat:@" (%@)", NSLocalizedString(@"inactive", "Torrent -> eta string")];
    }

    return idleString;
}

@end
#pragma clang diagnostic pop
