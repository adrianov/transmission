// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

#import "FilterBarController.h"
#import "FilterButton.h"
#import "GroupsController.h"
#import "NSStringAdditions.h"

FilterType const FilterTypeNone = @"None";
FilterType const FilterTypeActive = @"Active";
FilterType const FilterTypeDownload = @"Download";
FilterType const FilterTypeSeed = @"Seed";
FilterType const FilterTypePause = @"Pause";
FilterType const FilterTypeError = @"Error";

FilterSearchType const FilterSearchTypeName = @"Name";
FilterSearchType const FilterSearchTypeTracker = @"Tracker";

NSInteger const kGroupFilterAllTag = -2;

@interface FilterBarController ()

@property(nonatomic) IBOutlet FilterButton* fNoFilterButton;
@property(nonatomic) IBOutlet FilterButton* fActiveFilterButton;
@property(nonatomic) IBOutlet FilterButton* fDownloadFilterButton;
@property(nonatomic) IBOutlet FilterButton* fSeedFilterButton;
@property(nonatomic) IBOutlet FilterButton* fPauseFilterButton;
@property(nonatomic) IBOutlet FilterButton* fErrorFilterButton;

@property(nonatomic) IBOutlet NSPopUpButton* fGroupsButton;
@property(nonatomic) IBOutlet NSSearchField* fSearchField;

@end

@implementation FilterBarController

- (instancetype)init
{
    self = [super initWithNibName:@"FilterBar" bundle:nil];
    return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    //localizations
    self.fNoFilterButton.title = NSLocalizedString(@"All", "Filter Bar -> filter button");
    self.fActiveFilterButton.title = NSLocalizedString(@"Active", "Filter Bar -> filter button");
    self.fDownloadFilterButton.title = NSLocalizedString(@"Downloading", "Filter Bar -> filter button");
    self.fSeedFilterButton.title = NSLocalizedString(@"Seeding", "Filter Bar -> filter button");
    self.fPauseFilterButton.title = NSLocalizedString(@"Paused", "Filter Bar -> filter button");
    self.fErrorFilterButton.title = NSLocalizedString(@"Error", "Filter Bar -> filter button");

    self.fNoFilterButton.cell.backgroundStyle = NSBackgroundStyleRaised;
    self.fActiveFilterButton.cell.backgroundStyle = NSBackgroundStyleRaised;
    self.fDownloadFilterButton.cell.backgroundStyle = NSBackgroundStyleRaised;
    self.fSeedFilterButton.cell.backgroundStyle = NSBackgroundStyleRaised;
    self.fPauseFilterButton.cell.backgroundStyle = NSBackgroundStyleRaised;
    self.fErrorFilterButton.cell.backgroundStyle = NSBackgroundStyleRaised;

    [self.fGroupsButton.menu itemWithTag:kGroupFilterAllTag].title = NSLocalizedString(@"All Groups", "Filter Bar -> group filter menu");

    self.fSearchField.placeholderString = NSLocalizedString(@"Press Enter to Search on the rutracker.org...", "Filter Bar -> search field");

    //localize search menu
    NSMenuItem* nameItem = [self.fSearchField.searchMenuTemplate itemWithTag:0];
    NSMenuItem* trackerItem = [self.fSearchField.searchMenuTemplate itemWithTag:1];

    nameItem.title = NSLocalizedString(@"Name", "Filter Bar -> search filter");
    trackerItem.title = NSLocalizedString(@"Tracker", "Filter Bar -> search filter");

    //set current search type
    NSString* searchType = [NSUserDefaults.standardUserDefaults stringForKey:@"FilterSearchType"];
    if ([searchType isEqualToString:FilterSearchTypeTracker])
    {
        trackerItem.state = NSControlStateValueOn;
    }
    else
    {
        nameItem.state = NSControlStateValueOn;
    }

    //set current filter
    NSString* filterType = [NSUserDefaults.standardUserDefaults stringForKey:@"Filter"];

    NSButton* currentFilterButton;
    if ([filterType isEqualToString:FilterTypeActive])
    {
        currentFilterButton = self.fActiveFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypePause])
    {
        currentFilterButton = self.fPauseFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeSeed])
    {
        currentFilterButton = self.fSeedFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeDownload])
    {
        currentFilterButton = self.fDownloadFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeError])
    {
        currentFilterButton = self.fErrorFilterButton;
    }
    else
    {
        //safety
        if (![filterType isEqualToString:FilterTypeNone])
        {
            [NSUserDefaults.standardUserDefaults setObject:FilterTypeNone forKey:@"Filter"];
        }
        currentFilterButton = self.fNoFilterButton;
    }
    currentFilterButton.state = NSControlStateValueOn;

    [self updateGroupsButton];

    // update when groups change
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateGroups:) name:@"UpdateGroups" object:nil];
}

- (void)setSearchType:(id)sender
{
    FilterSearchType const searchType = [sender tag] == 1 ? FilterSearchTypeTracker : FilterSearchTypeName;
    [NSUserDefaults.standardUserDefaults setObject:searchType forKey:@"FilterSearchType"];

    NSMenuItem* nameItem = [self.fSearchField.searchMenuTemplate itemWithTag:0];
    NSMenuItem* trackerItem = [self.fSearchField.searchMenuTemplate itemWithTag:1];

    nameItem.state = [searchType isEqualToString:FilterSearchTypeName] ? NSControlStateValueOn : NSControlStateValueOff;
    trackerItem.state = [searchType isEqualToString:FilterSearchTypeTracker] ? NSControlStateValueOn : NSControlStateValueOff;

    [NSNotificationCenter.defaultCenter postNotificationName:@"ApplyFilter" object:nil];
}

- (void)setFilter:(id)sender
{
    NSString* oldFilterType = [NSUserDefaults.standardUserDefaults stringForKey:@"Filter"];

    NSButton* prevFilterButton;
    if ([oldFilterType isEqualToString:FilterTypePause])
    {
        prevFilterButton = self.fPauseFilterButton;
    }
    else if ([oldFilterType isEqualToString:FilterTypeActive])
    {
        prevFilterButton = self.fActiveFilterButton;
    }
    else if ([oldFilterType isEqualToString:FilterTypeSeed])
    {
        prevFilterButton = self.fSeedFilterButton;
    }
    else if ([oldFilterType isEqualToString:FilterTypeDownload])
    {
        prevFilterButton = self.fDownloadFilterButton;
    }
    else if ([oldFilterType isEqualToString:FilterTypeError])
    {
        prevFilterButton = self.fErrorFilterButton;
    }
    else
    {
        prevFilterButton = self.fNoFilterButton;
    }

    if (sender != prevFilterButton)
    {
        prevFilterButton.state = NSControlStateValueOff;
        [sender setState:NSControlStateValueOn];

        FilterType filterType;
        if (sender == self.fActiveFilterButton)
        {
            filterType = FilterTypeActive;
        }
        else if (sender == self.fDownloadFilterButton)
        {
            filterType = FilterTypeDownload;
        }
        else if (sender == self.fPauseFilterButton)
        {
            filterType = FilterTypePause;
        }
        else if (sender == self.fSeedFilterButton)
        {
            filterType = FilterTypeSeed;
        }
        else if (sender == self.fErrorFilterButton)
        {
            filterType = FilterTypeError;
        }
        else
        {
            filterType = FilterTypeNone;
        }

        [NSUserDefaults.standardUserDefaults setObject:filterType forKey:@"Filter"];
    }
    else
    {
        [sender setState:NSControlStateValueOn];
    }

    [NSNotificationCenter.defaultCenter postNotificationName:@"ApplyFilter" object:nil];
}

- (void)switchFilter:(BOOL)right
{
    NSString* filterType = [NSUserDefaults.standardUserDefaults stringForKey:@"Filter"];

    NSButton* button;
    if ([filterType isEqualToString:FilterTypeNone])
    {
        button = right ? self.fActiveFilterButton : self.fErrorFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeActive])
    {
        button = right ? self.fDownloadFilterButton : self.fNoFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeDownload])
    {
        button = right ? self.fSeedFilterButton : self.fActiveFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeSeed])
    {
        button = right ? self.fPauseFilterButton : self.fDownloadFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypePause])
    {
        button = right ? self.fErrorFilterButton : self.fSeedFilterButton;
    }
    else if ([filterType isEqualToString:FilterTypeError])
    {
        button = right ? self.fNoFilterButton : self.fPauseFilterButton;
    }
    else
    {
        button = self.fNoFilterButton;
    }

    [self setFilter:button];
}

- (void)setGroupFilter:(id)sender
{
    [NSUserDefaults.standardUserDefaults setInteger:[sender tag] forKey:@"FilterGroup"];
    [self updateGroupsButton];

    [NSNotificationCenter.defaultCenter postNotificationName:@"ApplyFilter" object:nil];
}

- (void)reset
{
    [NSUserDefaults.standardUserDefaults setInteger:kGroupFilterAllTag forKey:@"FilterGroup"];

    [self updateGroupsButton];

    [self setFilter:self.fNoFilterButton];
}

- (void)setCountAll:(NSUInteger)all
             active:(NSUInteger)active
        downloading:(NSUInteger)downloading
            seeding:(NSUInteger)seeding
             paused:(NSUInteger)paused
              error:(NSUInteger)error
{
    self.fNoFilterButton.count = all;
    self.fActiveFilterButton.count = active;
    self.fDownloadFilterButton.count = downloading;
    self.fSeedFilterButton.count = seeding;
    self.fPauseFilterButton.count = paused;
    self.fErrorFilterButton.count = error;
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
    if (menu == self.fGroupsButton.menu)
    {
        //remove all items except first three
        for (NSInteger i = menu.numberOfItems - 1; i >= 3; i--)
        {
            [menu removeItemAtIndex:i];
        }

        NSMenu* groupMenu = [GroupsController.groups groupMenuWithTarget:self action:@selector(setGroupFilter:) isSmall:YES];

        NSInteger const groupMenuCount = groupMenu.numberOfItems;
        for (NSInteger i = 0; i < groupMenuCount; i++)
        {
            NSMenuItem* item = [groupMenu itemAtIndex:0];
            [groupMenu removeItemAtIndex:0];
            [menu addItem:item];
        }
    }
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
    SEL const action = menuItem.action;

    if (action == @selector(setGroupFilter:))
    {
        menuItem.state = menuItem.tag == [NSUserDefaults.standardUserDefaults integerForKey:@"FilterGroup"] ? NSControlStateValueOn :
                                                                                                              NSControlStateValueOff;
        return YES;
    }

    return YES;
}

#pragma mark - Private

- (void)updateGroupsButton
{
    NSInteger const groupIndex = [NSUserDefaults.standardUserDefaults integerForKey:@"FilterGroup"];

    NSImage* icon;
    NSString* toolTip;
    if (groupIndex == kGroupFilterAllTag)
    {
        icon = [NSImage imageNamed:@"PinTemplate"];
        toolTip = NSLocalizedString(@"All Groups", "Groups -> Button");
    }
    else
    {
        icon = [GroupsController.groups imageForIndex:groupIndex];
        NSString* groupName = groupIndex != -1 ? [GroupsController.groups nameForIndex:groupIndex] :
                                                 NSLocalizedString(@"None", "Groups -> Button");
        toolTip = [NSLocalizedString(@"Group", "Groups -> Button") stringByAppendingFormat:@": %@", groupName];
    }

    [self.fGroupsButton.menu itemAtIndex:0].image = icon;
    self.fGroupsButton.toolTip = toolTip;
}

- (void)updateGroups:(NSNotification*)notification
{
    [self updateGroupsButton];
}

@end
