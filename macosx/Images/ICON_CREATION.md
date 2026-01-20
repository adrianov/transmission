# Creating Torrent Cell Button Icons

This document describes how to create icons for the torrent cell buttons (like Pause, Reveal, URL) that appear in the main torrent list.

## Icon Specifications

- **Size**: 14x14 pixels (1x) and 28x28 pixels (2x retina)
- **Format**: PNG with transparency
- **Background**: Semi-transparent black circle filling the entire icon
- **Foreground**: White icon/symbol

## Color Values

### Normal State (Off)
- Background: `rgba(0, 0, 0, 0.25)` - black with 25% opacity (alpha = 64/255)
- Foreground: `#FFFFFF` (white)

### Hover State
- Background: `rgba(0, 0, 0, 0.4)` - black with 40% opacity (alpha = 102/255)
- Foreground: `#FFFFFF` (white)

### Pressed State (On)
- Same as Hover state

## Creating Icons with SVG

### 1. Create the SVG template

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 28 28">
  <!-- Background circle - use r="14" to fill entire 28x28 space -->
  <circle cx="14" cy="14" r="14" fill="rgba(0,0,0,0.25)"/>
  
  <!-- Your icon graphic here in white -->
  <!-- Example: chain link icon -->
  <g transform="translate(14,14) rotate(45)">
    <rect x="-10" y="-2.2" width="9" height="4.4" rx="2.2" ry="2.2" 
          fill="none" stroke="white" stroke-width="2"/>
    <rect x="1" y="-2.2" width="9" height="4.4" rx="2.2" ry="2.2" 
          fill="none" stroke="white" stroke-width="2"/>
  </g>
</svg>
```

### 2. Convert SVG to PNG using rsvg-convert

```bash
# Install rsvg-convert if needed (macOS)
brew install librsvg

# Generate 1x (14x14) version
rsvg-convert -w 14 -h 14 icon.svg -o IconName.png

# Generate 2x (28x28) version  
rsvg-convert -w 28 -h 28 icon.svg -o IconName@2x.png
```

### 3. Create the imageset structure

For each icon state (Off, Hover, On), create a directory in `Images/Images.xcassets/`:

```
IconNameOff.imageset/
├── Contents.json
├── IconNameOff.png      (14x14)
└── IconNameOff@2x.png   (28x28)
```

### 4. Contents.json template

```json
{
  "images" : [
    {
      "idiom" : "mac",
      "filename" : "IconNameOff.png",
      "scale" : "1x"
    },
    {
      "idiom" : "mac",
      "filename" : "IconNameOff@2x.png",
      "scale" : "2x"
    }
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  },
  "properties" : {
    "template-rendering-intent" : "original"
  }
}
```

### 5. Register in CMakeLists.txt

Add your icon names to the `IMAGESETS` list in `macosx/CMakeLists.txt`:

```cmake
set(IMAGESETS
    ...
    IconNameOff
    IconNameHover
    IconNameOn
    ...)
```

## Complete Example: URL Button Icon

```bash
#!/bin/bash

# Create Off state SVG (25% opacity background)
cat > /tmp/URLOff.svg << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 28 28">
  <circle cx="14" cy="14" r="14" fill="rgba(0,0,0,0.25)"/>
  <g transform="translate(14,14) rotate(45)">
    <rect x="-10" y="-2.2" width="9" height="4.4" rx="2.2" ry="2.2" 
          fill="none" stroke="white" stroke-width="2"/>
    <rect x="1" y="-2.2" width="9" height="4.4" rx="2.2" ry="2.2" 
          fill="none" stroke="white" stroke-width="2"/>
  </g>
</svg>
EOF

# Create Hover state SVG (40% opacity background)
cat > /tmp/URLHover.svg << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 28 28">
  <circle cx="14" cy="14" r="14" fill="rgba(0,0,0,0.4)"/>
  <g transform="translate(14,14) rotate(45)">
    <rect x="-10" y="-2.2" width="9" height="4.4" rx="2.2" ry="2.2" 
          fill="none" stroke="white" stroke-width="2"/>
    <rect x="1" y="-2.2" width="9" height="4.4" rx="2.2" ry="2.2" 
          fill="none" stroke="white" stroke-width="2"/>
  </g>
</svg>
EOF

# On state same as Hover
cp /tmp/URLHover.svg /tmp/URLOn.svg

# Output directory
OUTDIR="macosx/Images/Images.xcassets"

# Generate PNGs for each state
for name in URLOff URLHover URLOn; do
    mkdir -p "$OUTDIR/${name}.imageset"
    rsvg-convert -w 14 -h 14 /tmp/${name}.svg -o "$OUTDIR/${name}.imageset/${name}.png"
    rsvg-convert -w 28 -h 28 /tmp/${name}.svg -o "$OUTDIR/${name}.imageset/${name}@2x.png"
done
```

## Verifying Icon Colors

Use Python/PIL to verify the alpha values match existing icons:

```python
from PIL import Image

img = Image.open("path/to/icon.png").convert("RGBA")
# Sample at edge of circle
pixel = img.getpixel((3, 14))
print(f"RGBA: {pixel}")  # Should be (0, 0, 0, 64) for Off state
```
