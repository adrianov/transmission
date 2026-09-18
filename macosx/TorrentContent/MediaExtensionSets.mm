// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "MediaExtensionSets.h"

NSSet<NSString*>* sVideoExtensions;
NSSet<NSString*>* sAudioExtensions;
NSSet<NSString*>* sBookExtensions;
NSSet<NSString*>* sSoftwareExtensions;
static dispatch_once_t sMediaExtensionsOnce;

void ensureMediaExtensionSets(void)
{
    dispatch_once(&sMediaExtensionsOnce, ^{
        sVideoExtensions = [NSSet setWithArray:@[
            @"mkv",
            @"avi",
            @"mp4",
            @"mov",
            @"wmv",
            @"flv",
            @"webm",
            @"m4v",
            @"mpg",
            @"mpeg",
            @"ts",
            @"m2ts",
            @"vob",
            @"3gp",
            @"ogv"
        ]];
        sAudioExtensions = [NSSet
            setWithArray:
                @[ @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus", @"wv" ]];
        sBookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
        sSoftwareExtensions = [NSSet
            setWithArray:@[ @"exe", @"msi", @"dmg", @"iso", @"pkg", @"deb", @"rpm", @"appimage", @"apk", @"run" ]];
    });
}
