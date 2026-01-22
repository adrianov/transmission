// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <Foundation/Foundation.h>

@class Torrent;

/// Converts DJVU files to PDF using libdjvu.
/// Conversion runs on a background thread and does not block the UI.
@interface DjvuConverter : NSObject

/// Check for completed DJVU files and convert them to PDF.
/// Called during torrent updates to convert files as they complete.
/// Tracks which files have been queued to avoid duplicate conversions.
+ (void)checkAndConvertCompletedFiles:(Torrent*)torrent;

/// Clear conversion tracking for a torrent (call when torrent is removed).
+ (void)clearTrackingForTorrent:(Torrent*)torrent;

/// Check if a PDF file is valid (can be opened and has readable pages).
+ (BOOL)isValidPdf:(NSString*)path;

@end
