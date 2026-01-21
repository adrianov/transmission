# Window Auto-Sizing (macOS)

The main window automatically resizes to fit torrent list content when AutoSize is enabled in preferences.

## How It Works

The window sizing algorithm in `Controller.mm` calculates the required height:

1. **Table content height:** Get the bottom edge of the last row using `NSOutlineView.rectOfRow:`
2. **Other UI components:** Measure dynamically by subtracting scroll view height from content view height
3. **Total content height:** Sum of table content and other components
4. **Window frame:** Convert content height to window frame using `frameRectForContentRect:`

## Screen Bounds Handling

The window is constrained to fit within the screen's visible area:

1. If window bottom goes below screen bottom → move window up
2. If window top goes above screen top → shrink height to fit
3. Window top position is kept fixed during normal resizing

## Key Implementation Details

### Content Height Calculation

```objc
// Get actual table content height from last row
NSInteger rowCount = self.fTableView.numberOfRows;
if (rowCount > 0) {
    NSRect lastRowRect = [self.fTableView rectOfRow:rowCount - 1];
    tableContentHeight = NSMaxY(lastRowRect);
}

// Measure other components dynamically
CGFloat currentContentHeight = self.fWindow.contentView.frame.size.height;
CGFloat currentScrollViewHeight = scrollView.frame.size.height;
CGFloat otherComponentsHeight = currentContentHeight - currentScrollViewHeight;

CGFloat contentHeight = tableContentHeight + otherComponentsHeight;
```

### Why This Approach

- **`rectOfRow:`** returns actual rendered row rectangles, accounting for variable heights (e.g., rows with play buttons)
- **Dynamic component measurement** works regardless of which bars are visible (status bar, filter bar, bottom bar)
- **No hardcoded heights** - adapts to UI changes automatically

## Related Files

- `macosx/Controller.mm` - `setWindowSizeToFit` method
- `macosx/TorrentTableView.mm` - `outlineView:heightOfRowByItem:` for variable row heights
