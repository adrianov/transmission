// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#include <libtransmission/transmission.h>
#include <libtransmission/utils.h>

#import "FileNameCellView.h"
#import "FileListNode.h"
#import "Torrent.h"
#import "NSStringAdditions.h"

static CGFloat const kPaddingHorizontal = 2.0;
static CGFloat const kImageFolderSize = 16.0;
static CGFloat const kImageIconSize = 32.0;
static CGFloat const kPaddingBetweenImageAndTitle = 4.0;
static CGFloat const kPaddingAboveTitleFile = 2.0;
static CGFloat const kPaddingBelowStatusFile = 2.0;
static CGFloat const kPaddingBetweenNameAndFolderStatus = 4.0;
static CGFloat const kPlayButtonSize = 22.0;
static CGFloat const kNameToPlaySpacing = 4.0;

/// Template play triangle for OS versions without SF Symbols (`play.fill`).
static NSImage* fileNamePlayTemplateImage(CGFloat side)
{
    NSSize size = NSMakeSize(side, side);
    NSImage* image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect /*rect*/) {
        CGFloat const w = size.width;
        CGFloat const h = size.height;
        CGFloat const margin = MAX(2.0, floor(w * 0.20));
        NSBezierPath* path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(margin, margin)];
        [path lineToPoint:NSMakePoint(w - margin * 1.5, h * 0.5)];
        [path lineToPoint:NSMakePoint(margin, h - margin)];
        [path closePath];
        [[NSColor blackColor] setFill];
        [path fill];
        return YES;
    }];
    [image setTemplate:YES];
    return image;
}

@interface FileNameCellView ()
@property(nonatomic, weak) NSImageView* iconView;
@property(nonatomic, weak) NSTextField* nameField;
@property(nonatomic, weak) NSTextField* statusField;
@property(nonatomic) NSButton* playButton;
@property(nonatomic, strong) NSArray<NSLayoutConstraint*>* dynamicConstraints;
@end

@implementation FileNameCellView

- (instancetype)initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect]))
    {
        // Create icon view
        NSImageView* iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        iconView.imageScaling = NSImageScaleProportionallyDown;
        [self addSubview:iconView];
        _iconView = iconView;

        // Create name field
        NSTextField* nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        nameField.translatesAutoresizingMaskIntoConstraints = NO;
        nameField.editable = NO;
        nameField.selectable = NO;
        nameField.bordered = NO;
        nameField.backgroundColor = NSColor.clearColor;
        nameField.font = [NSFont messageFontOfSize:12.0];
        nameField.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self addSubview:nameField];
        _nameField = nameField;
        self.textField = nameField;

        // Create status field
        NSTextField* statusField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        statusField.translatesAutoresizingMaskIntoConstraints = NO;
        statusField.editable = NO;
        statusField.selectable = NO;
        statusField.bordered = NO;
        statusField.backgroundColor = NSColor.clearColor;
        statusField.font = [NSFont messageFontOfSize:9.0];
        statusField.textColor = NSColor.secondaryLabelColor;
        statusField.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:statusField];
        _statusField = statusField;

        NSButton* playButton = [[NSButton alloc] initWithFrame:NSZeroRect];
        playButton.translatesAutoresizingMaskIntoConstraints = NO;
        playButton.bezelStyle = NSBezelStyleRoundRect;
        playButton.controlSize = NSControlSizeSmall;
        playButton.imagePosition = NSImageOnly;
        playButton.target = self;
        playButton.action = @selector(playPressed:);
        NSImage* playGlyph = nil;
        if (@available(macOS 11.0, *))
        {
            NSImage* playImg = [NSImage imageWithSystemSymbolName:@"play.fill"
                                         accessibilityDescription:NSLocalizedString(@"Play", "Inspector Files -> play file")];
            NSImageSymbolConfiguration* symCfg = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
            playGlyph = [playImg imageWithSymbolConfiguration:symCfg];
        }
        playButton.image = playGlyph ?: fileNamePlayTemplateImage(12.0);
        playButton.hidden = YES;
        [self addSubview:playButton];
        _playButton = playButton;

        // Setup constraints
        [self setupConstraints];
    }
    return self;
}

- (void)playPressed:(id __unused)sender
{
    if (self.playHandler != nil)
        self.playHandler();
}

- (void)setupConstraints
{
    NSImageView* iconView = self.iconView;
    NSTextField* nameField = self.nameField;

    // Fixed constraints that don't change
    [NSLayoutConstraint activateConstraints:@[
        // Icon view constraints
        [iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kPaddingHorizontal],
        [iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:kImageIconSize],
        [iconView.heightAnchor constraintEqualToConstant:kImageIconSize],

        // Name field leading constraint
        [nameField.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:kPaddingBetweenImageAndTitle],
    ]];

    self.dynamicConstraints = @[];
}

- (void)setNode:(FileListNode*)node
{
    _node = node;
    [self updateDisplay];
}

- (void)updateDisplay
{
    if (!self.node)
    {
        return;
    }

    FileListNode* node = self.node;

    // Update icon
    self.iconView.image = node.icon;

    // Update icon size constraints based on folder/file
    CGFloat const imageSize = node.isFolder ? kImageFolderSize : kImageIconSize;
    for (NSLayoutConstraint* constraint in self.iconView.constraints)
    {
        if (constraint.firstAttribute == NSLayoutAttributeWidth || constraint.firstAttribute == NSLayoutAttributeHeight)
        {
            constraint.constant = imageSize;
        }
    }

    // Update name
    self.nameField.stringValue = node.name;

    // Update status
    Torrent* torrent = node.torrent;
    CGFloat const progress = [torrent fileProgress:node];
    NSString* percentString = [NSString percentString:progress longDecimals:YES];

    NSString* status = [NSString stringWithFormat:NSLocalizedString(@"%@ of %@", "Inspector -> Files tab -> file status string"),
                                                  percentString,
                                                  [NSString stringForFileSize:node.size]];
    self.statusField.stringValue = status;

    // Update layout constraints based on folder vs file
    [NSLayoutConstraint deactivateConstraints:self.dynamicConstraints];

    NSTextField* nameField = self.nameField;
    NSTextField* statusField = self.statusField;

    if (node.isFolder)
    {
        // For folders, status appears next to name, both centered
        self.statusField.hidden = NO;
        self.playButton.hidden = YES;
        self.dynamicConstraints = @[
            [nameField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [nameField.trailingAnchor constraintLessThanOrEqualToAnchor:statusField.leadingAnchor
                                                               constant:-kPaddingBetweenNameAndFolderStatus],

            [statusField.leadingAnchor constraintEqualToAnchor:nameField.trailingAnchor constant:kPaddingBetweenNameAndFolderStatus],
            [statusField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [statusField.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
        ];
    }
    else
    {
        // For files, status appears below name; optional trailing Play (same as double-click).
        self.statusField.hidden = NO;
        NSString* openPath = [torrent pathToOpenForFileNode:node];
        BOOL const showPlay = openPath.length > 0 && [torrent mediaCategoryForFile:node.indexes.firstIndex] != nil;
        self.playButton.hidden = !showPlay;
        if (showPlay)
        {
            self.dynamicConstraints = @[
                [nameField.topAnchor constraintEqualToAnchor:self.topAnchor constant:kPaddingAboveTitleFile],
                [nameField.trailingAnchor constraintLessThanOrEqualToAnchor:self.playButton.leadingAnchor constant:-kNameToPlaySpacing],

                [statusField.leadingAnchor constraintEqualToAnchor:nameField.leadingAnchor],
                [statusField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
                [statusField.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-kPaddingBelowStatusFile],

                [self.playButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kPaddingHorizontal],
                [self.playButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                [self.playButton.widthAnchor constraintEqualToConstant:kPlayButtonSize],
                [self.playButton.heightAnchor constraintEqualToConstant:kPlayButtonSize],
            ];
        }
        else
        {
            self.dynamicConstraints = @[
                [nameField.topAnchor constraintEqualToAnchor:self.topAnchor constant:kPaddingAboveTitleFile],
                [nameField.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],

                [statusField.leadingAnchor constraintEqualToAnchor:nameField.leadingAnchor],
                [statusField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
                [statusField.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-kPaddingBelowStatusFile],
            ];
        }
    }

    [NSLayoutConstraint activateConstraints:self.dynamicConstraints];

    // Update colors based on background style and check state
    [self updateColors];

    // Update tooltip
    [self updateTooltip];
}

- (void)updateTooltip
{
    if (!self.node)
    {
        return;
    }

    FileListNode* node = self.node;
    Torrent* torrent = node.torrent;

    NSString* path = [torrent pathToOpenForFileNode:node];
    if (!path)
        path = [torrent fileLocation:node];
    if (!path)
        path = [node.path stringByAppendingPathComponent:node.name];

    NSString* openLabel = [torrent openCountLabelForFileNode:node];
    self.toolTip = openLabel.length > 0 ? [NSString stringWithFormat:@"%@\n%@", path, openLabel] : path;
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle
{
    [super setBackgroundStyle:backgroundStyle];
    [self updateColors];
}

- (void)updateColors
{
    if (self.backgroundStyle == NSBackgroundStyleEmphasized)
    {
        self.nameField.textColor = NSColor.whiteColor;
        self.statusField.textColor = NSColor.whiteColor;
        return;
    }
    if (!self.node)
    {
        self.nameField.textColor = NSColor.controlTextColor;
        self.statusField.textColor = NSColor.secondaryLabelColor;
        return;
    }
    FileListNode* node = self.node;
    Torrent* torrent = node.torrent;
    if ([torrent checkForFiles:node.indexes] == NSControlStateValueOff)
    {
        self.nameField.textColor = NSColor.disabledControlTextColor;
        self.statusField.textColor = NSColor.disabledControlTextColor;
    }
    else
    {
        self.nameField.textColor = NSColor.controlTextColor;
        self.statusField.textColor = NSColor.secondaryLabelColor;
    }
}

@end
