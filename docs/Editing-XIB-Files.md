# Editing XIB Files

XIB (XML Interface Builder) files define macOS UI layouts. They can be edited in Xcode's Interface Builder or directly as XML.

## Location

macOS XIB files are in `macosx/Base.lproj/`:
- `MainMenu.xib` - Main menu bar
- `PrefsWindow.xib` - Preferences window tabs
- `InfoWindow.xib` - Torrent Inspector window
- `InfoActivityView.xib` - Inspector Activity tab
- `InfoFilesView.xib` - Inspector Files tab
- etc.

## Editing in Xcode

1. Open `Transmission.xcodeproj` in Xcode
2. Navigate to the XIB file in the project navigator
3. Use Interface Builder to drag/drop controls
4. Connect outlets and actions via ctrl-drag

## Editing XIB XML Directly

XIB files are XML. Direct editing is useful for:
- Adding controls without opening Xcode
- Precise constraint adjustments
- Batch modifications

### Key Elements

**Views and Controls:**
```xml
<textField id="unique-id" translatesAutoresizingMaskIntoConstraints="NO">
    <rect key="frame" x="0" y="0" width="100" height="21"/>
    <textFieldCell key="cell" title="Label Text" .../>
</textField>
```

**Outlet Connections** (in File's Owner):
```xml
<outlet property="fMyField" destination="unique-id" id="connection-id"/>
```

**Action Connections** (in the control):
```xml
<connections>
    <action selector="myAction:" target="-2" id="action-id"/>
</connections>
```
Note: `-2` refers to File's Owner (the view controller).

**Auto Layout Constraints:**
```xml
<constraint firstItem="item1-id" firstAttribute="top" 
            secondItem="item2-id" secondAttribute="bottom" 
            constant="6" id="constraint-id"/>
```

### Common Constraint Attributes

- `top`, `bottom`, `leading`, `trailing` - edges
- `width`, `height` - dimensions
- `centerX`, `centerY` - centering
- `baseline` - text baseline alignment

### Adding a New Row (Example)

To add a label + field row below existing content:

1. **Add the label:**
```xml
<textField id="new-lb" translatesAutoresizingMaskIntoConstraints="NO">
    <rect key="frame" x="18" y="0" width="132" height="16"/>
    <textFieldCell key="cell" alignment="right" title="New Label:"/>
</textField>
```

2. **Add the field:**
```xml
<textField id="new-fld" translatesAutoresizingMaskIntoConstraints="NO">
    <rect key="frame" x="154" y="0" width="300" height="21"/>
    <textFieldCell key="cell" editable="YES" borderStyle="bezel" drawsBackground="YES"/>
    <connections>
        <action selector="setNewValue:" target="-2" id="new-act"/>
    </connections>
</textField>
```

3. **Add outlet in File's Owner connections:**
```xml
<outlet property="fNewField" destination="new-fld" id="new-out"/>
```

4. **Add constraints:**
```xml
<!-- Label width matches other labels -->
<constraint firstItem="new-lb" firstAttribute="width" secondItem="existing-label-id" secondAttribute="width"/>
<!-- Label trailing matches other labels -->
<constraint firstItem="new-lb" firstAttribute="trailing" secondItem="existing-label-id" secondAttribute="trailing"/>
<!-- Position below previous row -->
<constraint firstItem="new-lb" firstAttribute="top" secondItem="previous-row-id" secondAttribute="bottom" constant="6"/>
<!-- Field leading aligned with other fields -->
<constraint firstItem="new-fld" firstAttribute="leading" secondItem="existing-field-id" secondAttribute="leading"/>
<!-- Field vertically centered with label -->
<constraint firstItem="new-fld" firstAttribute="centerY" secondItem="new-lb" secondAttribute="centerY"/>
```

5. **Update parent view height** if needed:
```xml
<constraint firstAttribute="height" constant="NEW_HEIGHT" id="height-constraint-id"/>
```

### ID Conventions

- Use short, descriptive IDs for new elements: `prx-lb`, `prx-fld`, `cns-c1`
- Existing IDs are often numeric: `357`, `665`, `2081`
- Connection IDs should be unique

## Declaring Outlets in Code

In the view controller header (`.h`):
```objc
@property(nonatomic) IBOutlet NSTextField* fNewField;
```

In the implementation (`.mm`):
```objc
- (IBAction)setNewValue:(id)sender {
    // Handle the action
}
```

## Building

XIB files are compiled to NIB format during build:
```bash
cmake --build build -t transmission-mac
```

The build log shows XIB compilation:
```
Generating Base.lproj/PrefsWindow.nib
```

## Troubleshooting

**Constraint conflicts:** Check for duplicate or conflicting constraints. Each view needs unambiguous positioning.

**Missing outlets:** Ensure the outlet property name in code matches exactly what's in the XIB.

**Views not appearing:** Verify the view is added to the correct parent's `<subviews>` section.

**Wrong positioning:** Frame `rect` values are initial hints; Auto Layout constraints determine final position.
