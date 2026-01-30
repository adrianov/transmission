// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "ProgressBarView.h"
#import "ProgressGradients.h"
#import "TorrentTableView.h"
#import "Torrent.h"
#import "NSApplicationAdditions.h"

static CGFloat const kPiecesTotalPercent = 0.6;
static NSInteger const kMaxPieces = 18 * 18;
static float const kPieceCompleteEpsilon = 0.001f;

// NSColor redComponent/greenComponent/blueComponent throw if color is not in RGB/gray space (e.g. controlColor).
static void getRGBA(NSColor* color, CGFloat* r, CGFloat* g, CGFloat* b, CGFloat* a)
{
    NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
    if (!rgb)
    {
        rgb = [color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    }
    if (rgb)
    {
        [rgb getRed:r green:g blue:b alpha:a];
        return;
    }
    *r = *g = *b = 0.5;
    *a = 1.0;
}

@interface ProgressBarView ()

@property(nonatomic, readonly) NSUserDefaults* fDefaults;

@property(nonatomic, readonly) NSColor* fBarBorderColor;
@property(nonatomic, readonly) NSColor* fBluePieceColor;
@property(nonatomic, readonly) NSColor* fBarMinimalBorderColor;

@end

@implementation ProgressBarView

- (instancetype)init
{
    if ((self = [super init]))
    {
        _fDefaults = NSUserDefaults.standardUserDefaults;

        _fBluePieceColor = [NSColor colorWithCalibratedRed:0.0 green:0.4 blue:0.8 alpha:1.0];
        _fBarBorderColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.2];
        _fBarMinimalBorderColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.015];
    }
    return self;
}

- (void)drawBarInRect:(NSRect)barRect forTableView:(TorrentTableView*)tableView withTorrent:(Torrent*)torrent
{
    BOOL const minimal = [self.fDefaults boolForKey:@"SmallView"];

    CGFloat const piecesBarPercent = tableView.piecesBarPercent;
    if (piecesBarPercent > 0.0)
    {
        NSRect piecesBarRect, regularBarRect;
        NSDivideRect(barRect, &piecesBarRect, &regularBarRect, floor(NSHeight(barRect) * kPiecesTotalPercent * piecesBarPercent), NSMaxYEdge);

        [self drawRegularBar:regularBarRect forTorrent:torrent];
        [self drawPiecesBar:piecesBarRect forTorrent:torrent];
    }
    else
    {
        torrent.previousFinishedPieces = nil;

        [self drawRegularBar:barRect forTorrent:torrent];
    }

    NSColor* borderColor = minimal ? self.fBarMinimalBorderColor : self.fBarBorderColor;
    [borderColor set];
    [NSBezierPath strokeRect:NSInsetRect(barRect, 0.5, 0.5)];
}

- (void)drawRegularBar:(NSRect)barRect forTorrent:(Torrent*)torrent
{
    NSRect haveRect, missingRect;
    NSDivideRect(barRect, &haveRect, &missingRect, round(torrent.progress * NSWidth(barRect)), NSMinXEdge);

    if (!NSIsEmptyRect(haveRect))
    {
        if (torrent.active)
        {
            if (torrent.checking)
            {
                [ProgressGradients.progressYellowGradient drawInRect:haveRect angle:90];
            }
            else if (torrent.seeding)
            {
                NSRect ratioHaveRect, ratioRemainingRect;
                NSDivideRect(haveRect, &ratioHaveRect, &ratioRemainingRect, round(torrent.progressStopRatio * NSWidth(haveRect)), NSMinXEdge);

                [ProgressGradients.progressGreenGradient drawInRect:ratioHaveRect angle:90];
                [ProgressGradients.progressLightGreenGradient drawInRect:ratioRemainingRect angle:90];
            }
            else
            {
                [ProgressGradients.progressBlueGradient drawInRect:haveRect angle:90];
            }
        }
        else
        {
            if (torrent.waitingToStart)
            {
                if (torrent.allDownloaded)
                {
                    [ProgressGradients.progressDarkGreenGradient drawInRect:haveRect angle:90];
                }
                else
                {
                    [ProgressGradients.progressDarkBlueGradient drawInRect:haveRect angle:90];
                }
            }
            else
            {
                [ProgressGradients.progressGrayGradient drawInRect:haveRect angle:90];
            }
        }
    }

    if (!torrent.allDownloaded)
    {
        CGFloat const widthRemaining = round(NSWidth(barRect) * torrent.progressLeft);

        NSRect wantedRect;
        NSDivideRect(missingRect, &wantedRect, &missingRect, widthRemaining, NSMinXEdge);

        //not-available section
        if (torrent.active && !torrent.checking && torrent.availableDesired < 1.0 && [self.fDefaults boolForKey:@"DisplayProgressBarAvailable"])
        {
            NSRect unavailableRect;
            NSDivideRect(wantedRect, &wantedRect, &unavailableRect, round(NSWidth(wantedRect) * torrent.availableDesired), NSMinXEdge);

            [ProgressGradients.progressRedGradient drawInRect:unavailableRect angle:90];
        }

        //remaining section
        [ProgressGradients.progressWhiteGradient drawInRect:wantedRect angle:90];
    }

    //unwanted section
    if (!NSIsEmptyRect(missingRect))
    {
        if (!torrent.magnet)
        {
            [ProgressGradients.progressLightGrayGradient drawInRect:missingRect angle:90];
        }
        else
        {
            [ProgressGradients.progressRedGradient drawInRect:missingRect angle:90];
        }
    }
}

- (void)drawPiecesBar:(NSRect)barRect forTorrent:(Torrent*)torrent
{
    // Fill a solid color bar for magnet links
    if (torrent.magnet)
    {
        if (NSApp.darkMode)
        {
            [NSColor.controlColor set];
        }
        else
        {
            [[NSColor colorWithCalibratedWhite:1.0 alpha:[self.fDefaults boolForKey:@"SmallView"] ? 0.25 : 1.0] set];
        }
        NSRectFillUsingOperation(barRect, NSCompositingOperationSourceOver);
        return;
    }

    int const pieceCount = static_cast<int>(MIN(torrent.pieceCount, kMaxPieces));
    NSColor* const pieceBgColor = NSApp.darkMode ? NSColor.controlColor : NSColor.whiteColor;
    if (pieceCount <= 0)
    {
        torrent.previousFinishedPieces = nil;
        [pieceBgColor set];
        NSRectFillUsingOperation(barRect, NSCompositingOperationSourceOver);
        return;
    }

    NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:pieceCount pixelsHigh:1
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    if (!bitmap || !bitmap.bitmapData)
    {
        torrent.previousFinishedPieces = nil;
        [pieceBgColor set];
        NSRectFillUsingOperation(barRect, NSCompositingOperationSourceOver);
        return;
    }

    NSIndexSet* previousFinishedIndexes = torrent.previousFinishedPieces;
    NSMutableIndexSet* finishedIndexes = [NSMutableIndexSet indexSet];

    // Cache blue as bytes to avoid per-pixel NSColor access (hot path).
    NSColor* const blueColor = self.fBluePieceColor;
    CGFloat blueR, blueG, blueB, blueA;
    getRGBA(blueColor, &blueR, &blueG, &blueB, &blueA);
    unsigned char blueBytes[4] = {
        static_cast<unsigned char>(blueR * 255.0f + 0.5f),
        static_cast<unsigned char>(blueG * 255.0f + 0.5f),
        static_cast<unsigned char>(blueB * 255.0f + 0.5f),
        static_cast<unsigned char>(blueA * 255.0f + 0.5f),
    };

    if (torrent.allDownloaded)
    {
        for (int i = 0; i < pieceCount; i++)
        {
            [finishedIndexes addIndex:i];
            unsigned char* data = bitmap.bitmapData + (i << 2);
            data[0] = blueBytes[0];
            data[1] = blueBytes[1];
            data[2] = blueBytes[2];
            data[3] = blueBytes[3];
        }
        torrent.previousFinishedPieces = finishedIndexes;
    }
    else
    {
        CGFloat orangeR, orangeG, orangeB, orangeA;
        getRGBA(NSColor.orangeColor, &orangeR, &orangeG, &orangeB, &orangeA);
        unsigned char orangeBytes[4] = {
            static_cast<unsigned char>(orangeR * 255.0f + 0.5f),
            static_cast<unsigned char>(orangeG * 255.0f + 0.5f),
            static_cast<unsigned char>(orangeB * 255.0f + 0.5f),
            static_cast<unsigned char>(orangeA * 255.0f + 0.5f),
        };
        CGFloat bgR, bgG, bgB, bgA;
        getRGBA(pieceBgColor, &bgR, &bgG, &bgB, &bgA);
        float pieceBgF[4] = { static_cast<float>(bgR), static_cast<float>(bgG), static_cast<float>(bgB), static_cast<float>(bgA) };
        float blueF[4] = { static_cast<float>(blueR), static_cast<float>(blueG), static_cast<float>(blueB), static_cast<float>(blueA) };

        float* piecesPercent = static_cast<float*>(malloc(pieceCount * sizeof(float)));
        if (!piecesPercent)
        {
            torrent.previousFinishedPieces = nil;
            unsigned char bg[4] = {
                static_cast<unsigned char>(bgR * 255.0f + 0.5f),
                static_cast<unsigned char>(bgG * 255.0f + 0.5f),
                static_cast<unsigned char>(bgB * 255.0f + 0.5f),
                static_cast<unsigned char>(bgA * 255.0f + 0.5f),
            };
            for (int i = 0; i < pieceCount; i++)
            {
                unsigned char* data = bitmap.bitmapData + (i << 2);
                data[0] = bg[0];
                data[1] = bg[1];
                data[2] = bg[2];
                data[3] = bg[3];
            }
        }
        else
        {
            [torrent getAmountFinished:piecesPercent size:pieceCount];

            for (int i = 0; i < pieceCount; i++)
            {
                BOOL const complete = piecesPercent[i] >= (1.0f - kPieceCompleteEpsilon);
                unsigned char* data = bitmap.bitmapData + (i << 2);
                if (complete)
                {
                    BOOL const isNew = previousFinishedIndexes && ![previousFinishedIndexes containsIndex:i];
                    unsigned char const* src = isNew ? orangeBytes : blueBytes;
                    data[0] = src[0];
                    data[1] = src[1];
                    data[2] = src[2];
                    data[3] = src[3];
                    [finishedIndexes addIndex:i];
                }
                else
                {
                    float const f = piecesPercent[i];
                    for (int c = 0; c < 4; c++)
                    {
                        data[c] = static_cast<unsigned char>(((1.0f - f) * pieceBgF[c] + f * blueF[c]) * 255.0f + 0.5f);
                    }
                }
            }

            free(piecesPercent);
            torrent.previousFinishedPieces = finishedIndexes.count > 0 ? finishedIndexes : nil;
        }
    }

    [bitmap drawInRect:barRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
              fraction:[self.fDefaults boolForKey:@"SmallView"] ? 0.25 : 1.0
        respectFlipped:YES
                 hints:nil];
}

@end
