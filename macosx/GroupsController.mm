// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "GroupsController.h"
#import "NSImageAdditions.h"
#import "NSKeyedUnarchiverAdditions.h"
#import "NSMutableArrayAdditions.h"
#import "Torrent.h"

static CGFloat const kIconWidth = 16.0;
static CGFloat const kBorderWidth = 1.25;
static CGFloat const kIconWidthSmall = 12.0;

@interface GroupsController ()

@property(nonatomic, readonly) NSMutableArray<NSMutableDictionary*>* fGroups;

@end

@implementation GroupsController

GroupsController* fGroupsInstance = nil;

+ (GroupsController*)groups
{
    if (!fGroupsInstance)
    {
        fGroupsInstance = [[GroupsController alloc] init];
    }
    return fGroupsInstance;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        NSData* data;
        if ((data = [NSUserDefaults.standardUserDefaults dataForKey:@"GroupDicts"]))
        {
            _fGroups = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:NSMutableArray.class,
                                                                                          NSMutableDictionary.class,
                                                                                          NSNumber.class,
                                                                                          NSColor.class,
                                                                                          NSString.class,
                                                                                          NSPredicate.class,
                                                                                          nil]
                                                           fromData:data
                                                              error:nil];
        }
        else if ((data = [NSUserDefaults.standardUserDefaults dataForKey:@"Groups"])) //handle old groups
        {
            _fGroups = [NSKeyedUnarchiver deprecatedUnarchiveObjectWithData:data];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"Groups"];
            [self saveGroups];
        }
        if (_fGroups == nil)
        {
            _fGroups = [[NSMutableArray alloc] init];
        }

        // Ensure media-type groups exist for auto-assignment
        [self ensureMediaGroupsExist];
    }

    return self;
}

- (NSInteger)numberOfGroups
{
    return self.fGroups.count;
}

- (NSInteger)rowValueForIndex:(NSInteger)index
{
    if (index != -1)
    {
        for (NSUInteger i = 0; i < self.fGroups.count; i++)
        {
            if (index == [self.fGroups[i][@"Index"] integerValue])
            {
                return i;
            }
        }
    }
    return -1;
}

- (NSInteger)indexForRow:(NSInteger)row
{
    return [self.fGroups[row][@"Index"] integerValue];
}

- (NSString*)nameForIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    return orderIndex != -1 ? self.fGroups[orderIndex][@"Name"] : nil;
}

- (void)setName:(NSString*)name forIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    self.fGroups[orderIndex][@"Name"] = name;
    [self saveGroups];

    [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateGroups" object:self];
}

- (NSImage*)imageForIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    return orderIndex != -1 ? [self imageForGroup:self.fGroups[orderIndex]] : [self imageForGroupNone];
}

- (NSColor*)colorForIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    return orderIndex != -1 ? self.fGroups[orderIndex][@"Color"] : nil;
}

- (void)setColor:(NSColor*)color forIndex:(NSInteger)index
{
    NSMutableDictionary* dict = self.fGroups[[self rowValueForIndex:index]];
    [dict removeObjectForKey:@"Icon"];

    dict[@"Color"] = color;

    [GroupsController.groups saveGroups];
    [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateGroups" object:self];
}

- (BOOL)usesCustomDownloadLocationForIndex:(NSInteger)index
{
    if (![self customDownloadLocationForIndex:index])
    {
        return NO;
    }

    NSInteger orderIndex = [self rowValueForIndex:index];
    return [self.fGroups[orderIndex][@"UsesCustomDownloadLocation"] boolValue];
}

- (void)setUsesCustomDownloadLocation:(BOOL)useCustomLocation forIndex:(NSInteger)index
{
    NSMutableDictionary* dict = self.fGroups[[self rowValueForIndex:index]];

    dict[@"UsesCustomDownloadLocation"] = @(useCustomLocation);

    [GroupsController.groups saveGroups];
}

- (NSString*)customDownloadLocationForIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    return orderIndex != -1 ? self.fGroups[orderIndex][@"CustomDownloadLocation"] : nil;
}

- (void)setCustomDownloadLocation:(NSString*)location forIndex:(NSInteger)index
{
    NSMutableDictionary* dict = self.fGroups[[self rowValueForIndex:index]];
    dict[@"CustomDownloadLocation"] = location;

    [GroupsController.groups saveGroups];
}

- (BOOL)usesAutoAssignRulesForIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    if (orderIndex == -1)
    {
        return NO;
    }

    NSNumber* assignRules = self.fGroups[orderIndex][@"UsesAutoGroupRules"];
    return assignRules && assignRules.boolValue;
}

- (void)setUsesAutoAssignRules:(BOOL)useAutoAssignRules forIndex:(NSInteger)index
{
    NSMutableDictionary* dict = self.fGroups[[self rowValueForIndex:index]];

    dict[@"UsesAutoGroupRules"] = @(useAutoAssignRules);

    [GroupsController.groups saveGroups];
}

- (NSPredicate*)autoAssignRulesForIndex:(NSInteger)index
{
    NSInteger orderIndex = [self rowValueForIndex:index];
    if (orderIndex == -1)
    {
        return nil;
    }

    return self.fGroups[orderIndex][@"AutoGroupRules"];
}

- (void)setAutoAssignRules:(NSPredicate*)predicate forIndex:(NSInteger)index
{
    NSMutableDictionary* dict = self.fGroups[[self rowValueForIndex:index]];

    if (predicate)
    {
        dict[@"AutoGroupRules"] = predicate;
        [GroupsController.groups saveGroups];
    }
    else
    {
        [dict removeObjectForKey:@"AutoGroupRules"];
        [self setUsesAutoAssignRules:NO forIndex:index];
    }
}

- (void)addNewGroup
{
    //find the lowest index
    NSMutableIndexSet* candidates = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.fGroups.count + 1)];
    for (NSDictionary* dict in self.fGroups)
    {
        [candidates removeIndex:[dict[@"Index"] integerValue]];
    }

    NSInteger const index = candidates.firstIndex;

    [self.fGroups addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@(index),
                                                                              @"Index",
                                                                              [NSColor colorWithCalibratedRed:0.0 green:0.65
                                                                                                         blue:1.0
                                                                                                        alpha:1.0],
                                                                              @"Color",
                                                                              @"",
                                                                              @"Name",
                                                                              nil]];

    [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateGroups" object:self];
    [self saveGroups];
}

- (void)removeGroupWithRowIndex:(NSInteger)row
{
    NSInteger index = [self.fGroups[row][@"Index"] integerValue];
    [self.fGroups removeObjectAtIndex:row];

    [NSNotificationCenter.defaultCenter postNotificationName:@"GroupValueRemoved" object:self
                                                    userInfo:@{ @"Index" : @(index) }];

    if (index == [NSUserDefaults.standardUserDefaults integerForKey:@"FilterGroup"])
    {
        [NSUserDefaults.standardUserDefaults setInteger:-2 forKey:@"FilterGroup"];
    }

    [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateGroups" object:self];
    [self saveGroups];
}

- (void)moveGroupAtRow:(NSInteger)oldRow toRow:(NSInteger)newRow
{
    [self.fGroups moveObjectAtIndex:oldRow toIndex:newRow];

    [self saveGroups];
    [NSNotificationCenter.defaultCenter postNotificationName:@"UpdateGroups" object:self];
}

- (NSMenu*)groupMenuWithTarget:(id)target action:(SEL)action isSmall:(BOOL)small
{
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];

    void (^addItemWithTitleTagIcon)(NSString*, NSInteger, NSImage*) = ^void(NSString* title, NSInteger tag, NSImage* icon) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
        item.target = target;
        item.tag = tag;

        if (small)
        {
            icon = [icon copy];
            icon.size = NSMakeSize(kIconWidthSmall, kIconWidthSmall);

            item.image = icon;
        }
        else
        {
            item.image = icon;
        }

        [menu addItem:item];
    };

    addItemWithTitleTagIcon(NSLocalizedString(@"None", "Groups -> Menu"), -1, [self imageForGroupNone]);

    for (NSMutableDictionary* dict in self.fGroups)
    {
        addItemWithTitleTagIcon(dict[@"Name"], [dict[@"Index"] integerValue], [self imageForGroup:dict]);
    }

    return menu;
}

- (NSInteger)groupIndexForTorrent:(Torrent*)torrent
{
    // First, try explicit rules
    for (NSDictionary* group in self.fGroups)
    {
        NSInteger row = [group[@"Index"] integerValue];
        if ([self torrent:torrent doesMatchRulesForGroupAtIndex:row])
        {
            return row;
        }
    }

    // Fallback: auto-assign based on detected media category
    NSString* mediaCategory = torrent.detectedMediaCategory;
    if (mediaCategory)
    {
        NSInteger matchedIndex = [self groupIndexForMediaCategory:mediaCategory];
        if (matchedIndex != -1)
        {
            return matchedIndex;
        }
    }

    return -1;
}

/// Returns group index for a media category by matching group names.
/// Matches: "video" -> Video/Movies/Films, "audio" -> Audio/Music, "books" -> Books/Ebooks
- (NSInteger)groupIndexForMediaCategory:(NSString*)category
{
    static NSDictionary<NSString*, NSArray<NSString*>*>* categoryKeywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        categoryKeywords = @{
            @"video" : @[ @"video", @"movie", @"film", @"tv", @"serie" ],
            @"audio" : @[ @"audio", @"music", @"song", @"album" ],
            @"books" : @[ @"book", @"ebook", @"read", @"pdf", @"epub" ]
        };
    });

    NSArray<NSString*>* keywords = categoryKeywords[category];
    if (!keywords)
    {
        return -1;
    }

    for (NSDictionary* group in self.fGroups)
    {
        NSString* groupName = [group[@"Name"] lowercaseString];
        for (NSString* keyword in keywords)
        {
            if ([groupName containsString:keyword])
            {
                return [group[@"Index"] integerValue];
            }
        }
    }

    return -1;
}

#pragma mark - Private

/// Ensures Video, Audio, Books groups exist for media auto-assignment.
/// Creates missing groups without affecting existing user groups.
- (void)ensureMediaGroupsExist
{
    NSArray<NSDictionary*>* mediaGroups = @[
        @{
            @"name" : NSLocalizedString(@"Video", "Groups -> Name"),
            @"category" : @"video",
            @"color" : NSColor.systemBlueColor
        },
        @{
            @"name" : NSLocalizedString(@"Audio", "Groups -> Name"),
            @"category" : @"audio",
            @"color" : NSColor.systemPurpleColor
        },
        @{
            @"name" : NSLocalizedString(@"Books", "Groups -> Name"),
            @"category" : @"books",
            @"color" : NSColor.systemOrangeColor
        }
    ];

    BOOL groupsAdded = NO;
    for (NSDictionary* mediaDef in mediaGroups)
    {
        NSString* category = mediaDef[@"category"];

        // Check if a group matching this category already exists
        if ([self groupIndexForMediaCategory:category] == -1)
        {
            // Find next available index
            NSInteger maxIndex = -1;
            for (NSDictionary* group in self.fGroups)
            {
                NSInteger idx = [group[@"Index"] integerValue];
                if (idx > maxIndex)
                {
                    maxIndex = idx;
                }
            }

            NSMutableDictionary* newGroup = [NSMutableDictionary
                dictionaryWithObjectsAndKeys:mediaDef[@"color"], @"Color", mediaDef[@"name"], @"Name", @(maxIndex + 1), @"Index", nil];
            [self.fGroups addObject:newGroup];
            groupsAdded = YES;
        }
    }

    if (groupsAdded)
    {
        [self saveGroups];
    }
}

- (void)saveGroups
{
    //don't archive the icon
    NSMutableArray* groups = [NSMutableArray arrayWithCapacity:self.fGroups.count];
    for (NSDictionary* dict in self.fGroups)
    {
        NSMutableDictionary* tempDict = [dict mutableCopy];
        [tempDict removeObjectForKey:@"Icon"];
        [groups addObject:tempDict];
    }

    [NSUserDefaults.standardUserDefaults setObject:[NSKeyedArchiver archivedDataWithRootObject:groups requiringSecureCoding:YES
                                                                                         error:nil]
                                            forKey:@"GroupDicts"];
}

- (NSImage*)imageForGroupNone
{
    static NSImage* icon;
    if (icon)
    {
        return icon;
    }

    icon = [NSImage imageWithSize:NSMakeSize(kIconWidth, kIconWidth) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        //shape
        rect = NSInsetRect(rect, kBorderWidth / 2, kBorderWidth / 2);
        NSBezierPath* bp = [NSBezierPath bezierPathWithOvalInRect:rect];
        bp.lineWidth = kBorderWidth;

        //border
        // code reference for dashed style
        //CGFloat dashAndGapLength = M_PI * rect.size.width / 8;
        //CGFloat pattern[2] = { dashAndGapLength * .5, dashAndGapLength * .5 };
        //[bp setLineDash:pattern count:2 phase:0];

        [NSColor.controlTextColor setStroke];
        [bp stroke];

        return YES;
    }];
    [icon setTemplate:YES];

    return icon;
}

- (NSImage*)imageForGroup:(NSMutableDictionary*)dict
{
    NSImage* icon;
    if ((icon = dict[@"Icon"]))
    {
        return icon;
    }

    icon = [NSImage discIconWithColor:dict[@"Color"] insetFactor:0];

    dict[@"Icon"] = icon;

    return icon;
}

- (BOOL)torrent:(Torrent*)torrent doesMatchRulesForGroupAtIndex:(NSInteger)index
{
    if (![self usesAutoAssignRulesForIndex:index])
    {
        return NO;
    }

    NSPredicate* predicate = [self autoAssignRulesForIndex:index];
    [predicate allowEvaluation];
    BOOL eval = NO;
    @try
    {
        eval = [predicate evaluateWithObject:torrent];
    }
    @catch (NSException* exception)
    {
        NSLog(@"Error when evaluating predicate (%@) - %@", predicate, exception);
    }
    @finally
    {
        return eval;
    }
}

@end
