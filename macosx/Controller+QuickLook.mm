// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// QLPreviewPanelDataSource and QLPreviewPanelDelegate for Quick Look.

@import Quartz;

#import "ControllerPrivate.h"
#import "InfoWindowController.h"
#import "Torrent.h"
#import "TorrentTableView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation Controller (QuickLook)

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel*)panel
{
    return !self.fQuitting;
}

- (void)beginPreviewPanelControl:(QLPreviewPanel*)panel
{
    self.fPreviewPanel = panel;
    self.fPreviewPanel.delegate = self;
    self.fPreviewPanel.dataSource = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel*)panel
{
    self.fPreviewPanel = nil;
    [self.fWindow.toolbar validateVisibleItems];
}

- (NSArray<Torrent*>*)quickLookableTorrents
{
    NSArray* selectedTorrents = self.fTableView.selectedTorrents;
    NSMutableArray* qlArray = [NSMutableArray arrayWithCapacity:selectedTorrents.count];

    for (Torrent* torrent in selectedTorrents)
    {
        if ((torrent.folder || torrent.complete) && torrent.dataLocation)
            [qlArray addObject:torrent];
    }

    return qlArray;
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel*)panel
{
    if (self.fInfoController.canQuickLook)
        return self.fInfoController.quickLookURLs.count;
    return [self quickLookableTorrents].count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel*)panel previewItemAtIndex:(NSInteger)index
{
    if (self.fInfoController.canQuickLook)
        return self.fInfoController.quickLookURLs[index];
    return [self quickLookableTorrents][index];
}

- (BOOL)previewPanel:(QLPreviewPanel*)panel handleEvent:(NSEvent*)event
{
    return NO;
}

- (NSRect)previewPanel:(QLPreviewPanel*)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item
{
    if (self.fInfoController.canQuickLook)
        return [self.fInfoController quickLookSourceFrameForPreviewItem:item];

    if (!self.fWindow.visible)
        return NSZeroRect;

    NSInteger const row = [self.fTableView rowForItem:item];
    if (row == -1)
        return NSZeroRect;

    NSRect frame = [self.fTableView iconRectForRow:row];
    if (!NSIntersectsRect(self.fTableView.visibleRect, frame))
        return NSZeroRect;

    frame.origin = [self.fTableView convertPoint:frame.origin toView:nil];
    frame = [self.fWindow convertRectToScreen:frame];
    frame.origin.y -= frame.size.height;
    return frame;
}

@end
#pragma clang diagnostic pop
