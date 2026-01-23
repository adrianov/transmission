// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "Fb2Converter.h"
#import "FileListNode.h"
#import "Torrent.h"

// Track files that have been queued for conversion (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sConversionQueue = nil;
static NSMutableDictionary<NSString*, NSNumber*>* sLastScanTime = nil;
static dispatch_queue_t sConversionDispatchQueue = nil;

// Track files currently being converted (to avoid duplicate dispatches)
static NSMutableSet<NSString*>* sActiveConversions = nil;
// Track files pending dispatch (queued but not yet running)
static NSMutableSet<NSString*>* sPendingConversions = nil;
// Track files that failed to convert (by torrent hash -> set of file paths)
static NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* sFailedConversions = nil;

static BOOL isWhitespace(unichar c)
{
    return [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c];
}

static void appendSpaceIfNeeded(NSMutableString* text)
{
    if (text.length == 0)
        return;

    unichar last = [text characterAtIndex:text.length - 1];
    if (!isWhitespace(last))
    {
        [text appendString:@" "];
    }
}

static void appendSeparatorIfNeeded(NSMutableString* text)
{
    if (text.length == 0)
        return;

    unichar last = [text characterAtIndex:text.length - 1];
    if (!isWhitespace(last))
    {
        [text appendString:@" — "];
    }
}

static BOOL hasLeadingWhitespace(NSString* text)
{
    if (text.length == 0)
        return NO;

    return isWhitespace([text characterAtIndex:0]);
}

static NSString* collapseWhitespace(NSString* text)
{
    if (text.length == 0)
        return @"";

    NSMutableString* out = [NSMutableString string];
    BOOL seenSpace = NO;
    for (NSUInteger i = 0; i < text.length; ++i)
    {
        unichar c = [text characterAtIndex:i];
        if (isWhitespace(c))
        {
            seenSpace = YES;
            continue;
        }
        if (seenSpace && out.length > 0)
        {
            [out appendString:@" "];
        }
        seenSpace = NO;
        [out appendFormat:@"%C", c];
    }

    return out;
}

static void appendCollapsedText(NSMutableString* dest, NSString* text)
{
    NSString* collapsed = collapseWhitespace(text);
    if (collapsed.length == 0)
        return;

    BOOL leadingWhitespace = hasLeadingWhitespace(text);
    if (leadingWhitespace && dest.length > 0)
    {
        unichar last = [dest characterAtIndex:dest.length - 1];
        if (!isWhitespace(last))
        {
            [dest appendString:@" "];
        }
    }

    [dest appendString:collapsed];
}

static NSString* escapeXmlText(NSString* text)
{
    if (text.length == 0)
        return @"";

    NSMutableString* escaped = [text mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString* escapeHtmlText(NSString* text)
{
    if (text.length == 0)
        return @"";

    NSMutableString* escaped = [text mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

@interface Fb2Parser : NSObject<NSXMLParserDelegate>

@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly) NSString* language;
@property(nonatomic, readonly) NSString* author;
@property(nonatomic, readonly) NSString* bodyHtml;
@property(nonatomic, readonly) NSData* coverData;
@property(nonatomic, readonly) NSString* coverMime;
@property(nonatomic, readonly) NSArray<NSDictionary*>* tocItems;

- (BOOL)parseData:(NSData*)data;

@end

@implementation Fb2Parser
{
    NSMutableString* _titleBuffer;
    NSMutableString* _languageBuffer;
    NSMutableString* _authorFirst;
    NSMutableString* _authorLast;
    NSMutableString* _bodyBuffer;
    NSMutableString* _binaryBuffer;
    NSMutableArray<NSDictionary*>* _tocItems;
    NSMutableString* _headingBuffer;

    BOOL _inTitleInfo;
    BOOL _inBody;
    BOOL _sawBody;
    BOOL _inBookTitle;
    BOOL _inLanguage;
    BOOL _inAuthor;
    BOOL _inFirstName;
    BOOL _inLastName;

    BOOL _inParagraph;
    BOOL _inTitle;
    BOOL _inSubtitle;
    BOOL _inEmphasis;
    BOOL _inStrong;
    BOOL _inLink;
    NSInteger _headingLevel;
    NSUInteger _headingCount;

    NSString* _coverId;
    NSData* _coverData;
    NSString* _coverMime;
    BOOL _inBinary;
    NSString* _binaryId;
    NSString* _binaryMime;
}

- (BOOL)parseData:(NSData*)data
{
    _titleBuffer = [NSMutableString string];
    _languageBuffer = [NSMutableString string];
    _authorFirst = [NSMutableString string];
    _authorLast = [NSMutableString string];
    _bodyBuffer = [NSMutableString string];
    _binaryBuffer = nil;
    _tocItems = [NSMutableArray array];
    _headingBuffer = nil;
    _inTitleInfo = NO;
    _inBody = NO;
    _sawBody = NO;
    _inBookTitle = NO;
    _inLanguage = NO;
    _inAuthor = NO;
    _inFirstName = NO;
    _inLastName = NO;
    _inParagraph = NO;
    _inTitle = NO;
    _inSubtitle = NO;
    _inEmphasis = NO;
    _inStrong = NO;
    _inLink = NO;
    _headingLevel = 0;
    _headingCount = 0;
    _coverId = nil;
    _coverData = nil;
    _coverMime = nil;
    _inBinary = NO;
    _binaryId = nil;
    _binaryMime = nil;

    if (data.length == 0)
        return NO;

    NSXMLParser* parser = [[NSXMLParser alloc] initWithData:data];
    parser.shouldResolveExternalEntities = NO;
    parser.delegate = self;
    return [parser parse];
}

- (NSString*)title
{
    return [_titleBuffer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString*)language
{
    return [_languageBuffer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString*)author
{
    if (_authorFirst.length == 0 && _authorLast.length == 0)
        return @"";
    if (_authorFirst.length == 0)
        return [_authorLast stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_authorLast.length == 0)
        return [_authorFirst stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [NSString stringWithFormat:@"%@ %@",
                                      [_authorFirst stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
                                      [_authorLast stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
}

- (NSString*)bodyHtml
{
    return _bodyBuffer;
}

- (NSData*)coverData
{
    return _coverData;
}

- (NSString*)coverMime
{
    return _coverMime;
}

- (NSArray<NSDictionary*>*)tocItems
{
    return _tocItems;
}

- (void)parser:(NSXMLParser*)parser
    didStartElement:(NSString*)elementName
       namespaceURI:(NSString*)namespaceURI
      qualifiedName:(NSString*)qName
         attributes:(NSDictionary<NSString*, NSString*>*)attributeDict
{
    if ([elementName isEqualToString:@"title-info"])
    {
        _inTitleInfo = YES;
        return;
    }

    if ([elementName isEqualToString:@"body"])
    {
        if (!_sawBody)
        {
            _inBody = YES;
            _sawBody = YES;
        }
        return;
    }

    if (_inTitleInfo)
    {
        if ([elementName isEqualToString:@"image"] && _coverId.length == 0)
        {
            NSString* href = attributeDict[@"xlink:href"] ?: attributeDict[@"l:href"] ?: attributeDict[@"href"];
            if (href.length > 1 && [href hasPrefix:@"#"])
            {
                _coverId = [href substringFromIndex:1];
            }
            return;
        }
        if ([elementName isEqualToString:@"book-title"])
        {
            _inBookTitle = YES;
            return;
        }
        if ([elementName isEqualToString:@"lang"])
        {
            _inLanguage = YES;
            return;
        }
        if ([elementName isEqualToString:@"author"] && _authorFirst.length == 0 && _authorLast.length == 0)
        {
            _inAuthor = YES;
            return;
        }
        if (_inAuthor && [elementName isEqualToString:@"first-name"])
        {
            _inFirstName = YES;
            return;
        }
        if (_inAuthor && [elementName isEqualToString:@"last-name"])
        {
            _inLastName = YES;
            return;
        }
    }

    if ([elementName isEqualToString:@"binary"] && _coverId.length > 0 && _coverData == nil)
    {
        NSString* binaryId = attributeDict[@"id"];
        if (binaryId.length > 0 && [binaryId isEqualToString:_coverId])
        {
            _inBinary = YES;
            _binaryId = binaryId;
            _binaryMime = attributeDict[@"content-type"];
            _binaryBuffer = [NSMutableString string];
        }
        return;
    }

    if (!_inBody)
        return;

    if ([elementName isEqualToString:@"section"])
    {
        [_bodyBuffer appendString:@"<section>\n"];
        return;
    }
    if ([elementName isEqualToString:@"title"])
    {
        _inTitle = YES;
        _headingLevel = 1;
        _headingBuffer = [NSMutableString string];
        NSString* headingId = [NSString stringWithFormat:@"h%lu", (unsigned long)++_headingCount];
        [_bodyBuffer appendFormat:@"<h1 id=\"%@\">", headingId];
        return;
    }
    if ([elementName isEqualToString:@"subtitle"])
    {
        _inSubtitle = YES;
        _headingLevel = 2;
        _headingBuffer = [NSMutableString string];
        NSString* headingId = [NSString stringWithFormat:@"h%lu", (unsigned long)++_headingCount];
        [_bodyBuffer appendFormat:@"<h2 id=\"%@\">", headingId];
        return;
    }
    if ([elementName isEqualToString:@"p"] && (_inTitle || _inSubtitle))
    {
        appendSpaceIfNeeded(_bodyBuffer);
        if (_headingBuffer != nil)
        {
            appendSeparatorIfNeeded(_headingBuffer);
        }
        return;
    }
    if ([elementName isEqualToString:@"p"])
    {
        _inParagraph = YES;
        [_bodyBuffer appendString:@"<p>"];
        return;
    }
    if ([elementName isEqualToString:@"emphasis"])
    {
        _inEmphasis = YES;
        [_bodyBuffer appendString:@"<em>"];
        return;
    }
    if ([elementName isEqualToString:@"strong"])
    {
        _inStrong = YES;
        [_bodyBuffer appendString:@"<strong>"];
        return;
    }
    if ([elementName isEqualToString:@"empty-line"])
    {
        [_bodyBuffer appendString:@"<br />\n"];
        return;
    }
    if ([elementName isEqualToString:@"a"])
    {
        NSString* href = attributeDict[@"xlink:href"] ?: attributeDict[@"href"];
        if (href.length > 0)
        {
            _inLink = YES;
            NSString* escapedHref = escapeHtmlText(href);
            [_bodyBuffer appendFormat:@"<a href=\"%@\">", escapedHref];
        }
        return;
    }
}

- (void)parser:(NSXMLParser*)parser
    didEndElement:(NSString*)elementName
     namespaceURI:(NSString*)namespaceURI
    qualifiedName:(NSString*)qName
{
    if ([elementName isEqualToString:@"title-info"])
    {
        _inTitleInfo = NO;
        return;
    }
    if ([elementName isEqualToString:@"body"])
    {
        if (_inBody)
            _inBody = NO;
        return;
    }
    if ([elementName isEqualToString:@"book-title"])
    {
        _inBookTitle = NO;
        return;
    }
    if ([elementName isEqualToString:@"lang"])
    {
        _inLanguage = NO;
        return;
    }
    if ([elementName isEqualToString:@"author"])
    {
        _inAuthor = NO;
        _inFirstName = NO;
        _inLastName = NO;
        return;
    }
    if ([elementName isEqualToString:@"first-name"])
    {
        _inFirstName = NO;
        return;
    }
    if ([elementName isEqualToString:@"last-name"])
    {
        _inLastName = NO;
        return;
    }
    if ([elementName isEqualToString:@"binary"])
    {
        if (_inBinary)
        {
            _inBinary = NO;
            if (_binaryBuffer.length > 0)
            {
                NSData* decoded = [[NSData alloc] initWithBase64EncodedString:_binaryBuffer
                                                                      options:NSDataBase64DecodingIgnoreUnknownCharacters];
                if (decoded.length > 0)
                {
                    _coverData = decoded;
                    _coverMime = _binaryMime;
                }
            }
            _binaryBuffer = nil;
            _binaryId = nil;
            _binaryMime = nil;
        }
        return;
    }

    if (!_inBody)
        return;

    if ([elementName isEqualToString:@"p"] && (_inTitle || _inSubtitle))
    {
        return;
    }
    if ([elementName isEqualToString:@"section"])
    {
        [_bodyBuffer appendString:@"</section>\n"];
        return;
    }
    if ([elementName isEqualToString:@"title"])
    {
        _inTitle = NO;
        [_bodyBuffer appendString:@"</h1>\n"];
        if (_headingBuffer.length > 0)
        {
            NSString* headingId = [NSString stringWithFormat:@"h%lu", (unsigned long)_headingCount];
            [_tocItems addObject:@{ @"id" : headingId, @"title" : [_headingBuffer copy], @"level" : @(_headingLevel) }];
        }
        _headingBuffer = nil;
        _headingLevel = 0;
        return;
    }
    if ([elementName isEqualToString:@"subtitle"])
    {
        _inSubtitle = NO;
        [_bodyBuffer appendString:@"</h2>\n"];
        if (_headingBuffer.length > 0)
        {
            NSString* headingId = [NSString stringWithFormat:@"h%lu", (unsigned long)_headingCount];
            [_tocItems addObject:@{ @"id" : headingId, @"title" : [_headingBuffer copy], @"level" : @(_headingLevel) }];
        }
        _headingBuffer = nil;
        _headingLevel = 0;
        return;
    }
    if ([elementName isEqualToString:@"p"])
    {
        _inParagraph = NO;
        [_bodyBuffer appendString:@"</p>\n"];
        return;
    }
    if ([elementName isEqualToString:@"emphasis"])
    {
        _inEmphasis = NO;
        [_bodyBuffer appendString:@"</em>"];
        return;
    }
    if ([elementName isEqualToString:@"strong"])
    {
        _inStrong = NO;
        [_bodyBuffer appendString:@"</strong>"];
        return;
    }
    if ([elementName isEqualToString:@"a"])
    {
        if (_inLink)
        {
            _inLink = NO;
            [_bodyBuffer appendString:@"</a>"];
        }
        return;
    }
}

- (void)parser:(NSXMLParser*)parser foundCharacters:(NSString*)string
{
    if (string.length == 0)
        return;

    if (_inBinary)
    {
        [_binaryBuffer appendString:string];
        return;
    }

    if (_inBookTitle)
    {
        appendCollapsedText(_titleBuffer, string);
        return;
    }
    if (_inLanguage)
    {
        appendCollapsedText(_languageBuffer, string);
        return;
    }
    if (_inAuthor && _inFirstName)
    {
        appendCollapsedText(_authorFirst, string);
        return;
    }
    if (_inAuthor && _inLastName)
    {
        appendCollapsedText(_authorLast, string);
        return;
    }

    if (!_inBody)
        return;

    if (!(_inParagraph || _inTitle || _inSubtitle || _inEmphasis || _inStrong || _inLink))
        return;

    NSString* collapsed = collapseWhitespace(string);
    if (collapsed.length == 0)
        return;

    BOOL leadingWhitespace = hasLeadingWhitespace(string);
    if (leadingWhitespace && _bodyBuffer.length > 0)
    {
        unichar last = [_bodyBuffer characterAtIndex:_bodyBuffer.length - 1];
        if (!isWhitespace(last))
        {
            [_bodyBuffer appendString:@" "];
        }
    }

    NSString* escaped = escapeHtmlText(collapsed);
    [_bodyBuffer appendString:escaped];
    if ((_inTitle || _inSubtitle) && _headingBuffer != nil)
    {
        appendCollapsedText(_headingBuffer, string);
    }
}

@end

static NSString* epubTimestampUtc()
{
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [formatter stringFromDate:[NSDate date]];
}

static BOOL runZipCommand(NSString* zipPath, NSArray<NSString*>* arguments, NSString* workingDir)
{
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = zipPath;
    task.currentDirectoryPath = workingDir;
    task.arguments = arguments;
    task.standardOutput = nil;
    task.standardError = nil;

    @try
    {
        [task launch];
        [task waitUntilExit];
        return task.terminationStatus == 0;
    }
    @catch (NSException* exception)
    {
        return NO;
    }
}

static NSString* coverExtensionForMime(NSString* mime)
{
    NSString* lower = mime.lowercaseString;
    if ([lower isEqualToString:@"image/jpeg"] || [lower isEqualToString:@"image/jpg"])
        return @"jpg";
    if ([lower isEqualToString:@"image/png"])
        return @"png";
    if ([lower isEqualToString:@"image/gif"])
        return @"gif";
    if ([lower isEqualToString:@"image/webp"])
        return @"webp";
    return @"jpg";
}

static NSString* navItemsHtml(NSArray<NSDictionary*>* tocItems, BOOL includeCover, NSString* fallbackTitle)
{
    NSMutableString* items = [NSMutableString string];
    if (includeCover)
    {
        [items appendString:@"      <li><a href=\"cover.xhtml\">Cover</a></li>\n"];
    }

    if (tocItems.count == 0)
    {
        NSString* title = escapeHtmlText(fallbackTitle.length > 0 ? fallbackTitle : @"Book");
        [items appendFormat:@"      <li><a href=\"content.xhtml\">%@</a></li>\n", title];
        return items;
    }

    NSUInteger i = 0;
    while (i < tocItems.count)
    {
        NSDictionary* item = tocItems[i];
        NSInteger level = [item[@"level"] integerValue];
        if (level != 1)
            level = 1;

        NSString* itemId = item[@"id"];
        NSString* title = escapeHtmlText(item[@"title"] ?: @"");
        if (title.length == 0)
            title = @"Section";

        [items appendFormat:@"      <li><a href=\"content.xhtml#%@\">%@</a>", itemId, title];
        i++;

        NSMutableArray<NSDictionary*>* subItems = [NSMutableArray array];
        while (i < tocItems.count)
        {
            NSDictionary* next = tocItems[i];
            NSInteger nextLevel = [next[@"level"] integerValue];
            if (nextLevel != 2)
                break;
            [subItems addObject:next];
            i++;
        }

        if (subItems.count > 0)
        {
            [items appendString:@"\n        <ol>\n"];
            for (NSDictionary* sub in subItems)
            {
                NSString* subId = sub[@"id"];
                NSString* subTitle = escapeHtmlText(sub[@"title"] ?: @"");
                if (subTitle.length == 0)
                    subTitle = @"Section";
                [items appendFormat:@"          <li><a href=\"content.xhtml#%@\">%@</a></li>\n", subId, subTitle];
            }
            [items appendString:@"        </ol>\n      </li>\n"];
        }
        else
        {
            [items appendString:@"</li>\n"];
        }
    }

    return items;
}

static BOOL writeEpubFiles(
    NSString* workDir,
    NSString* title,
    NSString* author,
    NSString* language,
    NSString* bodyHtml,
    NSData* coverData,
    NSString* coverMime,
    NSArray<NSDictionary*>* tocItems)
{
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* metaInfDir = [workDir stringByAppendingPathComponent:@"META-INF"];
    NSString* oebpsDir = [workDir stringByAppendingPathComponent:@"OEBPS"];
    if (![fm createDirectoryAtPath:metaInfDir withIntermediateDirectories:YES attributes:nil error:nil])
        return NO;
    if (![fm createDirectoryAtPath:oebpsDir withIntermediateDirectories:YES attributes:nil error:nil])
        return NO;

    NSString* coverFileName = nil;
    NSString* coverMediaType = nil;
    if (coverData.length > 0)
    {
        NSString* ext = coverExtensionForMime(coverMime ?: @"image/jpeg");
        coverFileName = [@"cover." stringByAppendingString:ext];
        coverMediaType = coverMime.length > 0 ? coverMime : @"image/jpeg";
        NSString* coverPath = [oebpsDir stringByAppendingPathComponent:coverFileName];
        if (![coverData writeToFile:coverPath atomically:YES])
            return NO;
    }

    NSString* mimetypePath = [workDir stringByAppendingPathComponent:@"mimetype"];
    if (![@"application/epub+zip" writeToFile:mimetypePath atomically:YES encoding:NSASCIIStringEncoding error:nil])
        return NO;

    NSString* containerXml =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
         "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n"
         "  <rootfiles>\n"
         "    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>\n"
         "  </rootfiles>\n"
         "</container>\n";
    if (![containerXml writeToFile:[metaInfDir stringByAppendingPathComponent:@"container.xml"] atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:nil])
    {
        return NO;
    }

    NSString* safeTitle = escapeXmlText(title);
    NSString* safeAuthor = escapeXmlText(author);
    NSString* safeLang = escapeXmlText(language);
    NSString* identifier = [NSString stringWithFormat:@"urn:uuid:%@", NSUUID.UUID.UUIDString];
    NSString* modified = epubTimestampUtc();

    NSMutableString* opf = [NSMutableString string];
    [opf appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [opf appendString:@"<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">\n"];
    [opf appendString:@"  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"];
    [opf appendFormat:@"    <dc:identifier id=\"book-id\">%@</dc:identifier>\n", identifier];
    [opf appendFormat:@"    <dc:title>%@</dc:title>\n", safeTitle];
    [opf appendFormat:@"    <dc:language>%@</dc:language>\n", safeLang.length > 0 ? safeLang : @"en"];
    if (safeAuthor.length > 0)
    {
        [opf appendFormat:@"    <dc:creator>%@</dc:creator>\n", safeAuthor];
    }
    [opf appendFormat:@"    <meta property=\"dcterms:modified\">%@</meta>\n", modified];
    if (coverFileName != nil)
    {
        [opf appendString:@"    <meta name=\"cover\" content=\"cover-image\"/>\n"];
    }
    [opf appendString:@"  </metadata>\n"];
    [opf appendString:@"  <manifest>\n"];
    if (coverFileName != nil)
    {
        [opf appendFormat:@"    <item id=\"cover-image\" href=\"%@\" media-type=\"%@\" properties=\"cover-image\"/>\n", coverFileName, coverMediaType];
        [opf appendString:@"    <item id=\"cover\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\"/>\n"];
    }
    [opf appendString:@"    <item id=\"content\" href=\"content.xhtml\" media-type=\"application/xhtml+xml\"/>\n"];
    [opf appendString:@"    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"];
    [opf appendString:@"  </manifest>\n"];
    [opf appendString:@"  <spine>\n"];
    if (coverFileName != nil)
    {
        [opf appendString:@"    <itemref idref=\"cover\"/>\n"];
    }
    [opf appendString:@"    <itemref idref=\"content\"/>\n"];
    [opf appendString:@"  </spine>\n"];
    [opf appendString:@"</package>\n"];

    if (![opf writeToFile:[oebpsDir stringByAppendingPathComponent:@"content.opf"] atomically:YES encoding:NSUTF8StringEncoding
                    error:nil])
    {
        return NO;
    }

    NSString* htmlTitle = escapeHtmlText(title);
    NSString* htmlLang = language.length > 0 ? language : @"en";
    NSString* contentHtml = [NSString stringWithFormat:
                                          @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                                           "<!DOCTYPE html>\n"
                                           "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"%@\" lang=\"%@\">\n"
                                           "<head>\n"
                                           "  <meta charset=\"utf-8\" />\n"
                                           "  <title>%@</title>\n"
                                           "</head>\n"
                                           "<body>\n"
                                           "%@\n"
                                           "</body>\n"
                                           "</html>\n",
                                          htmlLang,
                                          htmlLang,
                                          htmlTitle.length > 0 ? htmlTitle : @"Book",
                                          bodyHtml];

    if (![contentHtml writeToFile:[oebpsDir stringByAppendingPathComponent:@"content.xhtml"] atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:nil])
    {
        return NO;
    }

    if (coverFileName != nil)
    {
        NSString* coverHtml = [NSString stringWithFormat:
                                            @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                                             "<!DOCTYPE html>\n"
                                             "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"%@\" lang=\"%@\">\n"
                                             "<head>\n"
                                             "  <meta charset=\"utf-8\" />\n"
                                             "  <title>%@</title>\n"
                                             "  <style>body{margin:0;padding:0;text-align:center;}img{max-width:100%%;height:auto;}</style>\n"
                                             "</head>\n"
                                             "<body>\n"
                                             "  <img src=\"%@\" alt=\"Cover\" />\n"
                                             "</body>\n"
                                             "</html>\n",
                                            htmlLang,
                                            htmlLang,
                                            htmlTitle.length > 0 ? htmlTitle : @"Cover",
                                            coverFileName];

        if (![coverHtml writeToFile:[oebpsDir stringByAppendingPathComponent:@"cover.xhtml"] atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil])
        {
            return NO;
        }
    }

    NSString* navTitle = htmlTitle.length > 0 ? htmlTitle : @"Book";
    NSString* navItems = navItemsHtml(tocItems, coverFileName != nil, navTitle);
    NSString* navHtml = [NSString stringWithFormat:
                                      @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                                       "<!DOCTYPE html>\n"
                                       "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n"
                                       "<head>\n"
                                       "  <meta charset=\"utf-8\" />\n"
                                       "  <title>Table of Contents</title>\n"
                                       "</head>\n"
                                       "<body>\n"
                                       "  <nav epub:type=\"toc\" id=\"toc\">\n"
                                       "    <ol>\n"
                                       "%@"
                                       "    </ol>\n"
                                       "  </nav>\n"
                                       "</body>\n"
                                       "</html>\n",
                                      navItems];

    if (![navHtml writeToFile:[oebpsDir stringByAppendingPathComponent:@"nav.xhtml"] atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil])
    {
        return NO;
    }

    return YES;
}

static BOOL convertFb2FileInternal(NSString* fb2Path, NSString* tmpEpubPath)
{
    if (fb2Path.length == 0 || tmpEpubPath.length == 0)
        return NO;

    NSData* data = [NSData dataWithContentsOfFile:fb2Path];
    if (!data || data.length == 0)
        return NO;

    Fb2Parser* parser = [[Fb2Parser alloc] init];
    if (![parser parseData:data])
        return NO;

    NSString* bodyHtml = parser.bodyHtml;
    if (bodyHtml.length == 0)
        return NO;

    NSString* baseName = fb2Path.lastPathComponent.stringByDeletingPathExtension;
    NSString* title = parser.title.length > 0 ? parser.title : baseName;
    NSString* author = parser.author;
    NSString* language = parser.language.length > 0 ? parser.language : @"en";

    NSString* workDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"fb2-epub-%@", [NSUUID UUID].UUIDString]];
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil])
        return NO;

    BOOL ok = writeEpubFiles(workDir, title, author, language, bodyHtml, parser.coverData, parser.coverMime, parser.tocItems);
    if (ok)
    {
        [fm removeItemAtPath:tmpEpubPath error:nil];
        NSString* zipPath = @"/usr/bin/zip";
        ok = runZipCommand(zipPath, @[ @"-X0", tmpEpubPath, @"mimetype" ], workDir);
        if (ok)
        {
            ok = runZipCommand(zipPath, @[ @"-X9", @"-r", tmpEpubPath, @"META-INF", @"OEBPS" ], workDir);
        }
    }

    [fm removeItemAtPath:workDir error:nil];
    return ok;
}

@implementation Fb2Converter

+ (void)initialize
{
    if (self == [Fb2Converter class])
    {
        sConversionQueue = [NSMutableDictionary dictionary];
        sLastScanTime = [NSMutableDictionary dictionary];
        dispatch_queue_attr_t attrs = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        sConversionDispatchQueue = dispatch_queue_create("com.transmissionbt.fb2converter", attrs);
    }
}

+ (void)checkAndConvertCompletedFiles:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return;

    NSString* torrentHash = torrent.hashString;

    // Throttle scans: this method is called frequently during UI updates.
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSNumber* lastScan = sLastScanTime[torrentHash];
    if (lastScan != nil && now - lastScan.doubleValue < 5.0)
        return;
    sLastScanTime[torrentHash] = @(now);

    NSArray<FileListNode*>* fileList = torrent.flatFileList;

    // Get or create tracking set for this torrent
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];
    if (!queuedFiles)
    {
        queuedFiles = [NSMutableSet set];
        sConversionQueue[torrentHash] = queuedFiles;
    }

    // Collect EPUB base names already in the torrent (no need to convert if torrent has EPUB)
    NSMutableSet<NSString*>* epubBaseNames = [NSMutableSet set];
    for (FileListNode* node in fileList)
    {
        if ([node.name.pathExtension.lowercaseString isEqualToString:@"epub"])
        {
            [epubBaseNames addObject:node.name.stringByDeletingPathExtension.lowercaseString];
        }
    }

    NSMutableArray<NSDictionary*>* filesToConvert = [NSMutableArray array];

    for (FileListNode* node in fileList)
    {
        NSString* name = node.name;
        NSString* ext = name.pathExtension.lowercaseString;

        // Only process FB2 files
        if (![ext isEqualToString:@"fb2"])
            continue;

        // Skip if torrent already contains an EPUB with the same base name
        NSString* baseName = name.stringByDeletingPathExtension.lowercaseString;
        if ([epubBaseNames containsObject:baseName])
            continue;

        // Check if file is 100% complete
        CGFloat progress = [torrent fileProgress:node];
        if (progress < 1.0)
            continue;

        NSString* path = [torrent fileLocation:node];
        if (!path)
            continue;

        NSString* epubPath = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"epub"];

        // Check if EPUB already exists on disk (converted previously)
        if ([NSFileManager.defaultManager fileExistsAtPath:epubPath])
        {
            [queuedFiles addObject:path];
            continue;
        }

        // Skip if already queued for conversion
        if ([queuedFiles containsObject:path])
            continue;

        // Mark as queued and add to conversion list
        [queuedFiles addObject:path];
        [filesToConvert addObject:@{ @"fb2" : path, @"epub" : epubPath }];
    }

    if (filesToConvert.count == 0)
        return;

    // Dispatch conversions via the shared path so we can track "active" vs "pending" work.
    [self ensureConversionDispatchedForTorrent:torrent];
}

+ (void)clearTrackingForTorrent:(Torrent*)torrent
{
    if (!torrent)
        return;

    NSString* hash = torrent.hashString;
    [sLastScanTime removeObjectForKey:hash];
    [sConversionQueue removeObjectForKey:hash];
    [sFailedConversions removeObjectForKey:hash];
}

+ (NSString*)convertingFileNameForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return nil;

    // Ensure static variables are initialized
    if (!sConversionQueue || !sConversionDispatchQueue)
        return nil;

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];

    if (!queuedFiles || queuedFiles.count == 0)
        return nil;

    // Find the first file that is actively converting and EPUB doesn't exist yet
    for (NSString* fb2Path in queuedFiles)
    {
        if (![sActiveConversions containsObject:fb2Path])
            continue;

        NSString* epubPath = [fb2Path.stringByDeletingPathExtension stringByAppendingPathExtension:@"epub"];
        if (![NSFileManager.defaultManager fileExistsAtPath:epubPath])
        {
            // Return the filename (last path component)
            return fb2Path.lastPathComponent;
        }
    }

    return nil;
}

+ (void)ensureConversionDispatchedForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return;

    if (!sConversionQueue || !sConversionDispatchQueue)
        return;

    if (!sActiveConversions)
        sActiveConversions = [NSMutableSet set];
    if (!sFailedConversions)
        sFailedConversions = [NSMutableDictionary dictionary];
    if (!sPendingConversions)
        sPendingConversions = [NSMutableSet set];

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* queuedFiles = sConversionQueue[torrentHash];

    if (!queuedFiles || queuedFiles.count == 0)
        return;

    NSMutableSet<NSString*>* failedForTorrent = sFailedConversions[torrentHash];
    if (!failedForTorrent)
    {
        failedForTorrent = [NSMutableSet set];
        sFailedConversions[torrentHash] = failedForTorrent;
    }

    // Find files that are queued but not actively being converted
    NSMutableArray<NSDictionary*>* filesToDispatch = [NSMutableArray array];

    for (NSString* fb2Path in queuedFiles)
    {
        NSString* epubPath = [fb2Path.stringByDeletingPathExtension stringByAppendingPathExtension:@"epub"];

        // Skip if EPUB already exists or conversion is already active/pending
        if ([NSFileManager.defaultManager fileExistsAtPath:epubPath])
            continue;
        if ([sActiveConversions containsObject:fb2Path])
            continue;
        if ([sPendingConversions containsObject:fb2Path])
            continue;
        if ([failedForTorrent containsObject:fb2Path])
            continue;

        [sPendingConversions addObject:fb2Path];
        [filesToDispatch addObject:@{ @"fb2" : fb2Path, @"epub" : epubPath }];
    }

    if (filesToDispatch.count == 0)
        return;

    NSString* notificationObject = [torrentHash copy];

    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary* file in filesToDispatch)
    {
        dispatch_group_async(group, sConversionDispatchQueue, ^{
            @autoreleasepool
            {
                NSString* fb2Path = file[@"fb2"];
                NSString* epubPath = file[@"epub"];
                BOOL success = YES;

                // Mark active when the worker actually begins (use async to avoid deadlock)
                dispatch_async(dispatch_get_main_queue(), ^{
                    [sActiveConversions addObject:fb2Path];
                });

                if (![NSFileManager.defaultManager fileExistsAtPath:epubPath])
                {
                    success = [self convertFb2File:fb2Path toEpub:epubPath];
                }

                // Remove from active set when done
                dispatch_async(dispatch_get_main_queue(), ^{
                    [sActiveConversions removeObject:fb2Path];
                    [sPendingConversions removeObject:fb2Path];
                    if (success)
                    {
                        [failedForTorrent removeObject:fb2Path];
                    }
                    else
                    {
                        [failedForTorrent addObject:fb2Path];
                    }
                });
            }
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"Fb2ConversionComplete" object:notificationObject];
    });
}

+ (NSString*)failedConversionFileNameForTorrent:(Torrent*)torrent
{
    if (!torrent || torrent.magnet)
        return nil;

    if (!sFailedConversions)
        return nil;

    NSString* torrentHash = torrent.hashString;
    NSMutableSet<NSString*>* failedFiles = sFailedConversions[torrentHash];
    if (!failedFiles || failedFiles.count == 0)
        return nil;

    // Collect files to remove (can't modify set while iterating)
    NSMutableArray<NSString*>* toRemove = [NSMutableArray array];
    NSString* firstFailed = nil;

    for (NSString* fb2Path in failedFiles)
    {
        // If an EPUB exists now, clear the failure entry
        NSString* epubPath = [fb2Path.stringByDeletingPathExtension stringByAppendingPathExtension:@"epub"];
        if ([NSFileManager.defaultManager fileExistsAtPath:epubPath])
        {
            [toRemove addObject:fb2Path];
            continue;
        }

        if (firstFailed == nil)
            firstFailed = fb2Path.lastPathComponent;
    }

    // Remove files that now have EPUBs
    for (NSString* path in toRemove)
        [failedFiles removeObject:path];

    return firstFailed;
}

+ (NSString*)convertingProgressForTorrent:(Torrent*)torrent
{
    (void)torrent;
    return nil;
}

+ (void)clearFailedConversionsForTorrent:(Torrent*)torrent
{
    if (!torrent || !sFailedConversions)
        return;

    [sFailedConversions removeObjectForKey:torrent.hashString];
}

+ (BOOL)convertFb2File:(NSString*)fb2Path toEpub:(NSString*)epubPath
{
    NSString* tmpEpubPath = [epubPath stringByAppendingFormat:@".tmp-%@", NSUUID.UUID.UUIDString];

    BOOL success = convertFb2FileInternal(fb2Path, tmpEpubPath);
    if (!success)
    {
        [NSFileManager.defaultManager removeItemAtPath:tmpEpubPath error:nil];
        return NO;
    }

    // Replace destination atomically to avoid ever exposing a partial EPUB.
    [NSFileManager.defaultManager removeItemAtPath:epubPath error:nil];
    if (![NSFileManager.defaultManager moveItemAtPath:tmpEpubPath toPath:epubPath error:nil])
    {
        [NSFileManager.defaultManager removeItemAtPath:tmpEpubPath error:nil];
        return NO;
    }

    return YES;
}

@end
