// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import <AppKit/AppKit.h>

@class FileListNode;

@interface FileNameCellView : NSTableCellView

@property(nonatomic, weak) FileListNode* node;
/// Opens the row’s file like double-click (Inspector). Set from `FileOutlineController` when the file is playable media.
@property(nonatomic, copy) void (^playHandler)(void);

@end
