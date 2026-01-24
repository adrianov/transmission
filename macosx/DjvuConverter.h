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

/// Get the filename of the first file being converted for a torrent, or nil if none.
/// Used to display conversion status in the UI.
+ (NSString*)convertingFileNameForTorrent:(Torrent*)torrent;

/// Ensure conversion is dispatched for any queued files that need it.
/// Call this to recover if conversion was not started properly.
+ (void)ensureConversionDispatchedForTorrent:(Torrent*)torrent;

/// Get the filename of a DJVU that failed to convert, if any.
+ (NSString*)failedConversionFileNameForTorrent:(Torrent*)torrent;

/// Get the page progress string ("X of Y pages") for current conversion.
+ (NSString*)convertingProgressForTorrent:(Torrent*)torrent;

/// Clear failed conversion tracking for a torrent (allows retry).
+ (void)clearFailedConversionsForTorrent:(Torrent*)torrent;

/// Get paths of converted PDF files for a torrent (for deletion when removing torrent with data).
+ (NSArray<NSString*>*)convertedFilesForTorrent:(Torrent*)torrent;

@end
