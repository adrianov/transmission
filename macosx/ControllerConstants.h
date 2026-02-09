// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Shared toolbar and sort constants for Controller and its categories.

#import <Foundation/Foundation.h>

typedef NSString* ToolbarItemIdentifier NS_TYPED_EXTENSIBLE_ENUM;

extern ToolbarItemIdentifier const ToolbarItemIdentifierCreate;
extern ToolbarItemIdentifier const ToolbarItemIdentifierOpenFile;
extern ToolbarItemIdentifier const ToolbarItemIdentifierOpenWeb;
extern ToolbarItemIdentifier const ToolbarItemIdentifierRemove;
extern ToolbarItemIdentifier const ToolbarItemIdentifierRemoveTrash;
extern ToolbarItemIdentifier const ToolbarItemIdentifierInfo;
extern ToolbarItemIdentifier const ToolbarItemIdentifierPauseAll;
extern ToolbarItemIdentifier const ToolbarItemIdentifierResumeAll;
extern ToolbarItemIdentifier const ToolbarItemIdentifierPauseResumeAll;
extern ToolbarItemIdentifier const ToolbarItemIdentifierPauseSelected;
extern ToolbarItemIdentifier const ToolbarItemIdentifierResumeSelected;
extern ToolbarItemIdentifier const ToolbarItemIdentifierPauseResumeSelected;
extern ToolbarItemIdentifier const ToolbarItemIdentifierFilter;
extern ToolbarItemIdentifier const ToolbarItemIdentifierQuickLook;
extern ToolbarItemIdentifier const ToolbarItemIdentifierShare;
extern ToolbarItemIdentifier const ToolbarItemIdentifierSearch;
extern ToolbarItemIdentifier const ToolbarItemIdentifierPlayRandomAudio;

typedef NS_ENUM(NSUInteger, ToolbarGroupTag) {
    ToolbarGroupTagPause = 0,
    ToolbarGroupTagResume = 1
};

typedef NSString* SortType NS_TYPED_EXTENSIBLE_ENUM;

extern SortType const SortTypeDate;
extern SortType const SortTypeName;
extern SortType const SortTypeState;
extern SortType const SortTypeProgress;
extern SortType const SortTypeTracker;
extern SortType const SortTypeOrder;
extern SortType const SortTypeActivity;
extern SortType const SortTypeSize;
extern SortType const SortTypeETA;

typedef NS_ENUM(NSUInteger, SortTag) {
    SortTagOrder = 0,
    SortTagDate = 1,
    SortTagName = 2,
    SortTagProgress = 3,
    SortTagState = 4,
    SortTagTracker = 5,
    SortTagActivity = 6,
    SortTagSize = 7,
    SortTagETA = 8
};

typedef NS_ENUM(NSUInteger, SortOrderTag) {
    SortOrderTagAscending = 0,
    SortOrderTagDescending = 1
};

extern NSString* const kTorrentTableViewDataType;

extern CGFloat const kStatusBarHeight;
extern CGFloat const kFilterBarHeight;
extern CGFloat const kBottomBarHeight;
