// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "TorrentCategoryTitle.h"

static BOOL titleContains(NSString* lower, NSString* keyword)
{
    return keyword.length > 0 && [lower containsString:keyword];
}

static BOOL titleContainsAny(NSString* lower, NSArray<NSString*>* keywords)
{
    for (NSString* keyword in keywords)
    {
        if (titleContains(lower, keyword))
            return YES;
    }
    return NO;
}

static BOOL titleMatchesRegex(NSString* title, NSRegularExpression* regex)
{
    return [regex firstMatchInString:title options:0 range:NSMakeRange(0, title.length)] != nil;
}

static NSString* categoryForExtension(NSString* ext)
{
    if (ext.length == 0)
        return nil;

    static NSSet<NSString*>* videoExtensions;
    static NSSet<NSString*>* audioExtensions;
    static NSSet<NSString*>* bookExtensions;
    static NSSet<NSString*>* softwareExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExtensions = [NSSet setWithArray:@[
            @"mkv", @"avi", @"mp4", @"mov", @"wmv", @"flv", @"webm", @"m4v", @"mpg", @"mpeg", @"ts", @"m2ts", @"vob", @"3gp", @"ogv"
        ]];
        audioExtensions = [NSSet
            setWithArray:@[ @"mp3", @"flac", @"wav", @"aac", @"ogg", @"wma", @"m4a", @"ape", @"alac", @"aiff", @"opus", @"wv" ]];
        bookExtensions = [NSSet setWithArray:@[ @"pdf", @"epub", @"djv", @"djvu", @"fb2", @"mobi" ]];
        softwareExtensions = [NSSet setWithArray:@[ @"exe", @"msi", @"dmg", @"iso", @"pkg", @"deb", @"rpm", @"appimage", @"apk", @"run" ]];
    });

    ext = ext.lowercaseString;
    if ([videoExtensions containsObject:ext])
        return @"video";
    if ([audioExtensions containsObject:ext])
        return @"audio";
    if ([bookExtensions containsObject:ext])
        return @"books";
    if ([softwareExtensions containsObject:ext])
        return @"software";
    return nil;
}

static BOOL titleHasMusicVideoIndicator(NSString* lower)
{
    return titleContains(lower, @"musicvideo") || titleContains(lower, @"music video");
}

static BOOL titleHasAudioIndicators(NSString* lower)
{
    if (titleHasMusicVideoIndicator(lower))
        return NO;

    static NSArray<NSString*>* keywords;
    static NSRegularExpression* bitrateRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"flac",
            @"[flac",
            @"mp3",
            @"320kbps",
            @"320 kbps",
            @"320_kbps",
            @" cd-rip",
            @"cd rip",
            @"discography",
            @"[eac",
            @"lossless",
            @" alac",
            @" aac",
            @" ape",
            @" opus",
            @" vtwin",
            @"bubanee",
            @" 2cd",
            @" 3cd"
        ];
        bitrateRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b320\\b" options:0 error:nil];
    });

    return titleContainsAny(lower, keywords) || titleMatchesRegex(lower, bitrateRegex);
}

static BOOL titleHasBookIndicators(NSString* lower)
{
    static NSArray<NSString*>* keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @" epub",
            @".epub",
            @" mobi",
            @".mobi",
            @" pdf",
            @".pdf",
            @" djvu",
            @".djvu",
            @" fb2",
            @" azw3",
            @" azw",
            @"e-book",
            @"ebook",
            @"(book)",
            @" book "
        ];
    });
    return titleContainsAny(lower, keywords);
}

static BOOL titleHasSoftwareIndicators(NSString* lower)
{
    static NSArray<NSString*>* keywords;
    static NSRegularExpression* sceneRegex;
    static NSRegularExpression* versionRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @" gog",
            @"-gog",
            @"skidrow",
            @"codex",
            @"tenoke",
            @"hoodlum",
            @"plaza",
            @"rune",
            @"simpex",
            @"reloaded",
            @"activator",
            @"microsoft office",
            @"microsoft windows",
            @"windows 10",
            @"windows 11",
            @"windows 7",
            @" macos",
            @"techtools",
            @"appdoze",
            @"thewindowsforum",
            @"unleashed",
            @"game dev",
            @"mmorpg tycoon",
            @"flight simulator"
        ];
        sceneRegex = [NSRegularExpression regularExpressionWithPattern:@"-(?:tenoke|skidrow|codex|gog|plaza|rune|hoodlum)\\b"
                                                               options:NSRegularExpressionCaseInsensitive
                                                                 error:nil];
        versionRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bv20\\d{2}(?:\\.\\d{2}){1,2}\\b"
                                                                 options:0
                                                                   error:nil];
    });

    return titleContainsAny(lower, keywords) || titleMatchesRegex(lower, sceneRegex) || titleMatchesRegex(lower, versionRegex);
}

static BOOL titleHasVideoIndicators(NSString* lower, NSString* title)
{
    static NSArray<NSString*>* keywords;
    static NSRegularExpression* episodeRegex;
    static NSRegularExpression* seasonRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"1080p",
            @"720p",
            @"480p",
            @"576p",
            @"2160p",
            @"4320p",
            @"4k",
            @"8k",
            @"web-dl",
            @"webrip",
            @"bluray",
            @"blu-ray",
            @"bdrip",
            @"bd-rip",
            @"dvdrip",
            @"dvdscr",
            @"tvrip",
            @"hdtv",
            @"x264",
            @"x265",
            @"h264",
            @"h265",
            @"hevc",
            @"xvid",
            @"divx",
            @" amzn",
            @" hmax",
            @"documentary",
            @"documental",
            @" docu",
            @" doku",
            @"brrip",
            @"remux",
            @"complete season",
            @"season pack"
        ];
        episodeRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bS\\d{1,2}[ ._-]?E\\d{1,3}\\b"
                                                                 options:NSRegularExpressionCaseInsensitive
                                                                   error:nil];
        seasonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\bS\\d{1,2}\\b.*\\b(?:complete|season)\\b"
                                                                options:NSRegularExpressionCaseInsensitive
                                                                  error:nil];
    });

    if (titleHasMusicVideoIndicator(lower))
        return YES;
    if (titleContainsAny(lower, keywords))
        return YES;
    return titleMatchesRegex(title, episodeRegex) || titleMatchesRegex(title, seasonRegex);
}

static BOOL titleHasAdultIndicators(NSString* lower, NSString* title)
{
    static NSArray<NSString*>* keywords;
    static NSRegularExpression* javRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"onlyfans",
            @" porn",
            @"[porn]",
            @" xxx",
            @"[xxx]",
            @" nsfw",
            @"[18+]",
            @"[adult]",
            @"pornhub",
            @"xvideos",
            @"ladyboy",
            @"-xxx",
            @" mp4-xxx"
        ];
        javRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\b(?:JUR|JUQ|JUL|ROE|ACHJ|SSIS|MIDE|IPX|FSDSS|MIMK|START|ABP|STARS|MIDV|CAWD|HND|MEYD|WAAA|DASS|PPPE|SONE|FAD|SDDE|SDMU|RCT|HEYZO|1PON|CARIB|10MU|FC2)-\\d{2,5}\\b"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:nil];
    });

    return titleContainsAny(lower, keywords) || titleMatchesRegex(title, javRegex);
}

NSString* TorrentMediaCategoryFromTitle(NSString* title)
{
    if (title.length == 0)
        return nil;

    NSString* const extCategory = categoryForExtension(title.pathExtension);
    if (extCategory != nil)
        return extCategory;

    NSString* lower = title.lowercaseString;

    if (titleHasBookIndicators(lower))
        return @"books";
    if (titleHasAudioIndicators(lower))
        return @"audio";
    if (titleHasSoftwareIndicators(lower))
        return @"software";

    if (titleHasVideoIndicators(lower, title))
    {
        if (titleHasAdultIndicators(lower, title))
            return @"adult";
        return @"video";
    }

    return nil;
}
