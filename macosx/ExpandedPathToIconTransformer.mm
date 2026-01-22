// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

@import AppKit;
@import UniformTypeIdentifiers;

#import "ExpandedPathToIconTransformer.h"

@implementation ExpandedPathToIconTransformer

+ (Class)transformedValueClass
{
    return [NSImage class];
}

+ (BOOL)allowsReverseTransformation
{
    return NO;
}

- (id)transformedValue:(id)value
{
    if (!value)
    {
        return nil;
    }

    NSString* path = [value stringByExpandingTildeInPath];
    NSImage* icon;
    //show a folder icon if the folder doesn't exist
    if ([path.pathExtension isEqualToString:@""] && ![NSFileManager.defaultManager fileExistsAtPath:path])
    {
        icon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypeFolder];
    }
    else
    {
        icon = [NSWorkspace.sharedWorkspace iconForFile:path];
    }

    icon.size = NSMakeSize(16.0, 16.0);

    return icon;
}

@end
