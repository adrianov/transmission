// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

@import Carbon;
@import QuartzCore;
@import UserNotifications;
@import UniformTypeIdentifiers;

@import Sparkle;

#include <sys/resource.h>

#include <libtransmission/transmission.h>

#include <libtransmission/log.h>
#include <libtransmission/torrent-metainfo.h>
#include <libtransmission/utils.h>
#include <libtransmission/values.h>
#include <libtransmission/variant.h>

#import "VDKQueue.h"

#import "CocoaCompatibility.h"

#import "Controller.h"
#import "ControllerConstants.h"
#import "ControllerPrivate.h"
#import "Torrent.h"
#import "TorrentGroup.h"
#import "TorrentTableView.h"
#import "CreatorWindowController.h"
#import "StatsWindowController.h"
#import "InfoWindowController.h"
#import "PrefsController.h"
#import "NSStringAdditions.h"
#import "GroupsController.h"
#import "AboutWindowController.h"
#import "URLSheetWindowController.h"
#import "AddWindowController.h"
#import "AddMagnetWindowController.h"
#import "MessageWindowController.h"
#import "GlobalOptionsPopoverViewController.h"
#import "ButtonToolbarItem.h"
#import "GroupToolbarItem.h"
#import "ShareToolbarItem.h"
#import "ShareTorrentFileHelper.h"
#import "Toolbar.h"
#import "BlocklistDownloader.h"
#import "StatusBarController.h"
#import "FilterBarController.h"
#import "FileRenameSheetController.h"
#import "BonjourController.h"
#import "Badger.h"
#import "DragOverlayWindow.h"
#import "NSImageAdditions.h"
#import "NSMutableArrayAdditions.h"
#import "NSStringAdditions.h"
#import "ExpandedPathToPathTransformer.h"
#import "ExpandedPathToIconTransformer.h"
#import "VersionComparator.h"
#import "PowerManager.h"
#import "DjvuConverter.h"
#import "Fb2Converter.h"

static CGFloat const kRowHeightRegular = 62.0;
static CGFloat const kRowHeightSmall = 22.0;

static NSTimeInterval const kUpdateUISeconds = 1.0;

static NSString* const kTransferPlist = @"Transfers.plist";

static NSString* const kWebsiteURL = @"https://transmissionbt.com/";
static NSString* const kForumURL = @"https://forum.transmissionbt.com/";
static NSString* const kGithubURL = @"https://github.com/transmission/transmission";
static NSString* const kDonateURL = @"https://transmissionbt.com/donate/";

static NSTimeInterval const kDonateNagTime = 60 * 60 * 24 * 7;

static void initUnits()
{
    using Config = libtransmission::Values::Config;

    // use a random value to avoid possible pluralization issues with 1 or 0 (an example is if we use 1 for bytes,
    // we'd get "byte" when we'd want "bytes" for the generic libtransmission value at least)
    int const ArbitraryPluralNumber = 17;

    NSByteCountFormatter* unitFormatter = [[NSByteCountFormatter alloc] init];
    unitFormatter.includesCount = NO;
    unitFormatter.allowsNonnumericFormatting = NO;
    unitFormatter.allowedUnits = NSByteCountFormatterUseBytes;
    NSString* b_str = [unitFormatter stringFromByteCount:ArbitraryPluralNumber];
    unitFormatter.allowedUnits = NSByteCountFormatterUseKB;
    NSString* k_str = [unitFormatter stringFromByteCount:ArbitraryPluralNumber];
    unitFormatter.allowedUnits = NSByteCountFormatterUseMB;
    NSString* m_str = [unitFormatter stringFromByteCount:ArbitraryPluralNumber];
    unitFormatter.allowedUnits = NSByteCountFormatterUseGB;
    NSString* g_str = [unitFormatter stringFromByteCount:ArbitraryPluralNumber];
    unitFormatter.allowedUnits = NSByteCountFormatterUseTB;
    NSString* t_str = [unitFormatter stringFromByteCount:ArbitraryPluralNumber];
    Config::memory = { Config::Base::Kilo, b_str.UTF8String, k_str.UTF8String,
                       m_str.UTF8String,   g_str.UTF8String, t_str.UTF8String };
    Config::storage = { Config::Base::Kilo, b_str.UTF8String, k_str.UTF8String,
                        m_str.UTF8String,   g_str.UTF8String, t_str.UTF8String };

    b_str = NSLocalizedString(@"B/s", "Transfer speed (bytes per second)");
    k_str = NSLocalizedString(@"KB/s", "Transfer speed (kilobytes per second)");
    m_str = NSLocalizedString(@"MB/s", "Transfer speed (megabytes per second)");
    g_str = NSLocalizedString(@"GB/s", "Transfer speed (gigabytes per second)");
    t_str = NSLocalizedString(@"TB/s", "Transfer speed (terabytes per second)");
    Config::speed = { Config::Base::Kilo, b_str.UTF8String, k_str.UTF8String,
                      m_str.UTF8String,   g_str.UTF8String, t_str.UTF8String };
}

static void altSpeedToggledCallback([[maybe_unused]] tr_session* handle, bool active, bool byUser, void* controller)
{
    NSDictionary* dict = @{@"Active" : @(active), @"ByUser" : @(byUser)};
    [(__bridge Controller*)controller performSelectorOnMainThread:@selector(altSpeedToggledCallbackIsLimited:) withObject:dict
                                                    waitUntilDone:NO];
}

static tr_rpc_callback_status rpcCallback([[maybe_unused]] tr_session* handle, tr_rpc_callback_type type, struct tr_torrent* torrentStruct, void* controller)
{
    [(__bridge Controller*)controller rpcCallback:type forTorrentStruct:torrentStruct];
    return TR_RPC_NOREMOVE; //we'll do the remove manually
}

// 2.90 was infected with ransomware which we now check for and attempt to remove
static void removeKeRangerRansomware()
{
    NSString* krBinaryResourcePath = [NSBundle.mainBundle pathForResource:@"General" ofType:@"rtf"];

    NSString* userLibraryDirPath = [NSHomeDirectory() stringByAppendingString:@"/Library"];
    NSString* krLibraryKernelServicePath = [userLibraryDirPath stringByAppendingString:@"/kernel_service"];

    NSFileManager* fileManager = NSFileManager.defaultManager;

    NSArray<NSString*>* krFilePaths = @[
        krBinaryResourcePath ? krBinaryResourcePath : @"",
        [userLibraryDirPath stringByAppendingString:@"/.kernel_pid"],
        [userLibraryDirPath stringByAppendingString:@"/.kernel_time"],
        [userLibraryDirPath stringByAppendingString:@"/.kernel_complete"],
        krLibraryKernelServicePath
    ];

    BOOL foundKrFiles = NO;
    for (NSString* krFilePath in krFilePaths)
    {
        if (krFilePath.length == 0 || ![fileManager fileExistsAtPath:krFilePath])
        {
            continue;
        }

        foundKrFiles = YES;
        break;
    }

    if (!foundKrFiles)
    {
        return;
    }

    NSLog(@"Detected OSX.KeRanger.A ransomware, trying to remove it");

    if ([fileManager fileExistsAtPath:krLibraryKernelServicePath])
    {
        // The forgiving way: kill process which has the file opened
        NSTask* lsofTask = [[NSTask alloc] init];
        lsofTask.launchPath = @"/usr/sbin/lsof";
        lsofTask.arguments = @[ @"-F", @"pid", @"--", krLibraryKernelServicePath ];
        lsofTask.standardOutput = [NSPipe pipe];
        lsofTask.standardInput = [NSPipe pipe];
        lsofTask.standardError = lsofTask.standardOutput;
        [lsofTask launch];
        NSData* lsofOutputData = [[lsofTask.standardOutput fileHandleForReading] readDataToEndOfFile];
        [lsofTask waitUntilExit];
        NSString* lsofOutput = [[NSString alloc] initWithData:lsofOutputData encoding:NSUTF8StringEncoding];
        for (NSString* line in [lsofOutput componentsSeparatedByString:@"\n"])
        {
            if (![line hasPrefix:@"p"])
            {
                continue;
            }
            pid_t const krProcessId = [line substringFromIndex:1].intValue;
            if (kill(krProcessId, SIGKILL) == -1)
            {
                NSLog(@"Unable to forcibly terminate ransomware process (kernel_service, pid %d), please do so manually", krProcessId);
            }
        }
    }
    else
    {
        // The harsh way: kill all processes with matching name
        NSTask* killTask = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/killall" arguments:@[ @"-9", @"kernel_service" ]];
        [killTask waitUntilExit];
        if (killTask.terminationStatus != 0)
        {
            NSLog(@"Unable to forcibly terminate ransomware process (kernel_service), please do so manually if it's currently running");
        }
    }

    for (NSString* krFilePath in krFilePaths)
    {
        if (krFilePath.length == 0 || ![fileManager fileExistsAtPath:krFilePath])
        {
            continue;
        }

        if (![fileManager removeItemAtPath:krFilePath error:NULL])
        {
            NSLog(@"Unable to remove ransomware file at %@, please do so manually", krFilePath);
        }
    }

    NSLog(@"OSX.KeRanger.A ransomware removal completed, proceeding to normal operation");
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol" // QLPreviewPanelDataSource/Delegate implemented in Controller+QuickLook.mm
@implementation Controller

+ (void)initialize
{
    if (self != [Controller self])
        return;

    removeKeRangerRansomware();

    //make sure another Transmission.app isn't running already
    NSArray* apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier];
    if (apps.count > 1)
    {
        NSAlert* alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", "Transmission already running alert -> button")];
        alert.messageText = NSLocalizedString(@"Transmission is already running.", "Transmission already running alert -> title");
        alert.informativeText = NSLocalizedString(
            @"There is already a copy of Transmission running. "
             "This copy cannot be opened until that instance is quit.",
            "Transmission already running alert -> message");
        alert.alertStyle = NSAlertStyleCritical;

        [alert runModal];

        //kill ourselves right away
        exit(0);
    }

    [NSUserDefaults.standardUserDefaults
        registerDefaults:[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"Defaults" ofType:@"plist"]]];

    //set custom value transformers
    ExpandedPathToPathTransformer* pathTransformer = [[ExpandedPathToPathTransformer alloc] init];
    [NSValueTransformer setValueTransformer:pathTransformer forName:@"ExpandedPathToPathTransformer"];

    ExpandedPathToIconTransformer* iconTransformer = [[ExpandedPathToIconTransformer alloc] init];
    [NSValueTransformer setValueTransformer:iconTransformer forName:@"ExpandedPathToIconTransformer"];
}

void onStartQueue(tr_session* /*session*/, tr_torrent* /*tor*/, void* /*vself*/)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        //posting asynchronously with coalescing to prevent stack overflow on lots of torrents changing state at the same time
        [NSNotificationQueue.defaultQueue enqueueNotification:[NSNotification notificationWithName:@"UpdateTorrentsState" object:nil]
                                                 postingStyle:NSPostASAP
                                                 coalesceMask:NSNotificationCoalescingOnName
                                                     forModes:nil];
    });
}

void onIdleLimitHit(tr_session* /*session*/, tr_torrent* tor, void* vself)
{
    auto* const controller = (__bridge Controller*)(vself);
    auto const hashstr = @(tr_torrentView(tor).hash_string);

    dispatch_async(dispatch_get_main_queue(), ^{
        auto* const torrent = [controller torrentForHash:hashstr];
        [torrent idleLimitHit];
    });
}

void onRatioLimitHit(tr_session* /*session*/, tr_torrent* tor, void* vself)
{
    auto* const controller = (__bridge Controller*)(vself);
    auto const hashstr = @(tr_torrentView(tor).hash_string);

    dispatch_async(dispatch_get_main_queue(), ^{
        auto* const torrent = [controller torrentForHash:hashstr];
        [torrent ratioLimitHit];
    });
}

void onMetadataCompleted(tr_session* /*session*/, tr_torrent* tor, void* vself)
{
    auto* const controller = (__bridge Controller*)(vself);
    auto const hashstr = @(tr_torrentView(tor).hash_string);

    dispatch_async(dispatch_get_main_queue(), ^{
        auto* const torrent = [controller torrentForHash:hashstr];
        [torrent metadataRetrieved];
    });
}

void onTorrentCompletenessChanged(tr_torrent* tor, tr_completeness status, bool wasRunning, void* vself)
{
    auto* const controller = (__bridge Controller*)(vself);
    auto const hashstr = @(tr_torrentView(tor).hash_string);

    dispatch_async(dispatch_get_main_queue(), ^{
        auto* const torrent = [controller torrentForHash:hashstr];
        [torrent completenessChange:status wasRunning:wasRunning];
    });
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _fDefaults = NSUserDefaults.standardUserDefaults;

        //checks for old version speeds of -1
        if ([_fDefaults integerForKey:@"UploadLimit"] < 0)
        {
            [_fDefaults removeObjectForKey:@"UploadLimit"];
            [_fDefaults setBool:NO forKey:@"CheckUpload"];
        }
        if ([_fDefaults integerForKey:@"DownloadLimit"] < 0)
        {
            [_fDefaults removeObjectForKey:@"DownloadLimit"];
            [_fDefaults setBool:NO forKey:@"CheckDownload"];
        }

        //upgrading from versions < 2.40: clear recent items
        [NSDocumentController.sharedDocumentController clearRecentDocuments:nil];

        auto settings = tr_sessionGetDefaultSettings();

        BOOL const usesSpeedLimitSched = [_fDefaults boolForKey:@"SpeedLimitAuto"];
        if (!usesSpeedLimitSched)
        {
            tr_variantDictAddBool(&settings, TR_KEY_alt_speed_enabled, [_fDefaults boolForKey:@"SpeedLimit"]);
        }

        tr_variantDictAddInt(&settings, TR_KEY_alt_speed_up, [_fDefaults integerForKey:@"SpeedLimitUploadLimit"]);
        tr_variantDictAddInt(&settings, TR_KEY_alt_speed_down, [_fDefaults integerForKey:@"SpeedLimitDownloadLimit"]);

        tr_variantDictAddBool(&settings, TR_KEY_alt_speed_time_enabled, [_fDefaults boolForKey:@"SpeedLimitAuto"]);
        tr_variantDictAddInt(&settings, TR_KEY_alt_speed_time_begin, [PrefsController dateToTimeSum:[_fDefaults objectForKey:@"SpeedLimitAutoOnDate"]]);
        tr_variantDictAddInt(&settings, TR_KEY_alt_speed_time_end, [PrefsController dateToTimeSum:[_fDefaults objectForKey:@"SpeedLimitAutoOffDate"]]);
        tr_variantDictAddInt(&settings, TR_KEY_alt_speed_time_day, [_fDefaults integerForKey:@"SpeedLimitAutoDay"]);

        tr_variantDictAddInt(&settings, TR_KEY_speed_limit_down, [_fDefaults integerForKey:@"DownloadLimit"]);
        tr_variantDictAddBool(&settings, TR_KEY_speed_limit_down_enabled, [_fDefaults boolForKey:@"CheckDownload"]);
        tr_variantDictAddInt(&settings, TR_KEY_speed_limit_up, [_fDefaults integerForKey:@"UploadLimit"]);
        tr_variantDictAddBool(&settings, TR_KEY_speed_limit_up_enabled, [_fDefaults boolForKey:@"CheckUpload"]);

        //hidden prefs
        if ([_fDefaults objectForKey:@"BindAddressIPv4"])
        {
            tr_variantDictAddStr(&settings, TR_KEY_bind_address_ipv4, [_fDefaults stringForKey:@"BindAddressIPv4"].UTF8String);
        }
        if ([_fDefaults objectForKey:@"BindAddressIPv6"])
        {
            tr_variantDictAddStr(&settings, TR_KEY_bind_address_ipv6, [_fDefaults stringForKey:@"BindAddressIPv6"].UTF8String);
        }

        tr_variantDictAddBool(&settings, TR_KEY_blocklist_enabled, [_fDefaults boolForKey:@"BlocklistNew"]);
        if ([_fDefaults objectForKey:@"BlocklistURL"])
            tr_variantDictAddStr(&settings, TR_KEY_blocklist_url, [_fDefaults stringForKey:@"BlocklistURL"].UTF8String);
        tr_variantDictAddBool(&settings, TR_KEY_dht_enabled, [_fDefaults boolForKey:@"DHTGlobal"]);
        tr_variantDictAddStr(
            &settings,
            TR_KEY_download_dir,
            [_fDefaults stringForKey:@"DownloadFolder"].stringByExpandingTildeInPath.UTF8String);
        tr_variantDictAddBool(&settings, TR_KEY_download_queue_enabled, [_fDefaults boolForKey:@"Queue"]);
        tr_variantDictAddInt(&settings, TR_KEY_download_queue_size, [_fDefaults integerForKey:@"QueueDownloadNumber"]);
        tr_variantDictAddInt(&settings, TR_KEY_idle_seeding_limit, [_fDefaults integerForKey:@"IdleLimitMinutes"]);
        tr_variantDictAddBool(&settings, TR_KEY_idle_seeding_limit_enabled, [_fDefaults boolForKey:@"IdleLimitCheck"]);
        tr_variantDictAddStr(
            &settings,
            TR_KEY_incomplete_dir,
            [_fDefaults stringForKey:@"IncompleteDownloadFolder"].stringByExpandingTildeInPath.UTF8String);
        tr_variantDictAddBool(&settings, TR_KEY_incomplete_dir_enabled, [_fDefaults boolForKey:@"UseIncompleteDownloadFolder"]);
        tr_variantDictAddBool(&settings, TR_KEY_torrent_complete_verify_enabled, [_fDefaults boolForKey:@"VerifyDataOnCompletion"]);
        tr_variantDictAddBool(&settings, TR_KEY_lpd_enabled, [_fDefaults boolForKey:@"LocalPeerDiscoveryGlobal"]);
        tr_variantDictAddInt(&settings, TR_KEY_message_level, TR_LOG_DEBUG);
        tr_variantDictAddInt(&settings, TR_KEY_peer_limit_global, [_fDefaults integerForKey:@"PeersTotal"]);
        tr_variantDictAddInt(&settings, TR_KEY_peer_limit_per_torrent, [_fDefaults integerForKey:@"PeersTorrent"]);

        NSInteger bindPort = [_fDefaults integerForKey:@"BindPort"];
        if (bindPort <= 0 || bindPort > 65535)
        {
            // First launch, we avoid a default port to be less likely blocked on such port and to have more chances of success when connecting to swarms.
            // Ideally, we should be setting port 0, then reading the port number assigned by the system and save that value. But that would be best handled by libtransmission itself.
            // For now, we randomize the port as a Dynamic/Private/Ephemeral Port from 49152–65535
            // https://datatracker.ietf.org/doc/html/rfc6335#section-6
            uint16_t defaultPort = 49152 + arc4random_uniform(65536 - 49152);
            [_fDefaults setInteger:defaultPort forKey:@"BindPort"];
        }

        BOOL const randomPort = [_fDefaults boolForKey:@"RandomPort"];
        tr_variantDictAddBool(&settings, TR_KEY_peer_port_random_on_start, randomPort);
        if (!randomPort)
        {
            tr_variantDictAddInt(&settings, TR_KEY_peer_port, [_fDefaults integerForKey:@"BindPort"]);
        }

        //hidden pref
        if ([_fDefaults objectForKey:@"PeerSocketTOS"])
        {
            tr_variantDictAddStr(&settings, TR_KEY_peer_socket_diffserv, [_fDefaults stringForKey:@"PeerSocketTOS"].UTF8String);
        }

        tr_variantDictAddBool(&settings, TR_KEY_pex_enabled, [_fDefaults boolForKey:@"PEXGlobal"]);
        tr_variantDictAddBool(&settings, TR_KEY_port_forwarding_enabled, [_fDefaults boolForKey:@"NatTraversal"]);
        tr_variantDictAddBool(&settings, TR_KEY_queue_stalled_enabled, [_fDefaults boolForKey:@"CheckStalled"]);
        tr_variantDictAddInt(&settings, TR_KEY_queue_stalled_minutes, [_fDefaults integerForKey:@"StalledMinutes"]);
        tr_variantDictAddReal(&settings, TR_KEY_ratio_limit, [_fDefaults floatForKey:@"RatioLimit"]);
        tr_variantDictAddBool(&settings, TR_KEY_ratio_limit_enabled, [_fDefaults boolForKey:@"RatioCheck"]);
        tr_variantDictAddBool(&settings, TR_KEY_rename_partial_files, [_fDefaults boolForKey:@"RenamePartialFiles"]);
        tr_variantDictAddBool(&settings, TR_KEY_rpc_authentication_required, [_fDefaults boolForKey:@"RPCAuthorize"]);
        tr_variantDictAddBool(&settings, TR_KEY_rpc_enabled, [_fDefaults boolForKey:@"RPC"]);
        tr_variantDictAddInt(&settings, TR_KEY_rpc_port, [_fDefaults integerForKey:@"RPCPort"]);
        tr_variantDictAddStr(&settings, TR_KEY_rpc_username, [_fDefaults stringForKey:@"RPCUsername"].UTF8String);
        tr_variantDictAddBool(&settings, TR_KEY_rpc_whitelist_enabled, [_fDefaults boolForKey:@"RPCUseWhitelist"]);
        tr_variantDictAddBool(&settings, TR_KEY_rpc_host_whitelist_enabled, [_fDefaults boolForKey:@"RPCUseHostWhitelist"]);
        tr_variantDictAddBool(&settings, TR_KEY_seed_queue_enabled, [_fDefaults boolForKey:@"QueueSeed"]);
        tr_variantDictAddInt(&settings, TR_KEY_seed_queue_size, [_fDefaults integerForKey:@"QueueSeedNumber"]);
        tr_variantDictAddBool(&settings, TR_KEY_start_added_torrents, [_fDefaults boolForKey:@"AutoStartDownload"]);
        tr_variantDictAddBool(&settings, TR_KEY_utp_enabled, [_fDefaults boolForKey:@"UTPGlobal"]);

        tr_variantDictAddBool(&settings, TR_KEY_script_torrent_done_enabled, [_fDefaults boolForKey:@"DoneScriptEnabled"]);
        NSString* prefs_string = [_fDefaults stringForKey:@"DoneScriptPath"];
        if (prefs_string != nil)
        {
            tr_variantDictAddStr(&settings, TR_KEY_script_torrent_done_filename, prefs_string.UTF8String);
        }

        // TODO: Add to GUI
        if ([_fDefaults objectForKey:@"RPCHostWhitelist"])
        {
            tr_variantDictAddStr(&settings, TR_KEY_rpc_host_whitelist, [_fDefaults stringForKey:@"RPCHostWhitelist"].UTF8String);
        }

        initUnits();

        auto const default_config_dir = tr_getDefaultConfigDir("Transmission");
        _fLib = tr_sessionInit(default_config_dir, YES, settings);
        _fConfigDirectory = @(default_config_dir.c_str());

        tr_sessionSetIdleLimitHitCallback(_fLib, onIdleLimitHit, (__bridge void*)(self));
        tr_sessionSetQueueStartCallback(_fLib, onStartQueue, (__bridge void*)(self));
        tr_sessionSetRatioLimitHitCallback(_fLib, onRatioLimitHit, (__bridge void*)(self));
        tr_sessionSetMetadataCallback(_fLib, onMetadataCompleted, (__bridge void*)(self));
        tr_sessionSetCompletenessCallback(_fLib, onTorrentCompletenessChanged, (__bridge void*)(self));

        NSApp.delegate = self;

        //register for magnet URLs (has to be in init)
        [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self
                                                           andSelector:@selector(handleOpenContentsEvent:replyEvent:)
                                                         forEventClass:kInternetEventClass
                                                            andEventID:kAEGetURL];

        _fTorrents = [[NSMutableArray alloc] init];
        _fDisplayedTorrents = [[NSMutableArray alloc] init];
        _fTorrentHashes = [[NSMutableDictionary alloc] init];

        NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        _fSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];

        _fInfoController = [[InfoWindowController alloc] init];

        //needs to be done before init-ing the prefs controller
        _fileWatcherQueue = [[VDKQueue alloc] init];
        _fileWatcherQueue.delegate = self;

        _prefsController = [[PrefsController alloc] initWithHandle:_fLib];

        _fQuitting = NO;
        _fGlobalPopoverShown = NO;
        _fSoundPlaying = NO;

        tr_sessionSetAltSpeedFunc(_fLib, altSpeedToggledCallback, (__bridge void*)(self));
        if (usesSpeedLimitSched)
        {
            [_fDefaults setBool:tr_sessionUsesAltSpeed(_fLib) forKey:@"SpeedLimit"];
        }

        tr_sessionSetRPCCallback(_fLib, rpcCallback, (__bridge void*)(self));

        [SUUpdater sharedUpdater].delegate = self;
        _fQuitRequested = NO;

        _fPauseOnLaunch = (GetCurrentKeyModifiers() & (optionKey | rightOptionKey)) != 0;
    }
    return self;
}

- (void)removeMissingDataTorrentsOnLaunch
{
    if (self.fTorrents.count == 0)
    {
        return;
    }

    // Run file checks asynchronously to avoid blocking UI on startup
    NSArray<Torrent*>* torrents = [self.fTorrents copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [Torrent updateTorrents:torrents];

        NSMutableArray<Torrent*>* toRemove = [NSMutableArray array];
        for (Torrent* torrent in torrents)
        {
            if (torrent.error && torrent.allFilesMissing)
            {
                [toRemove addObject:torrent];
            }
        }

        if (toRemove.count == 0)
        {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            for (Torrent* torrent in toRemove)
            {
                [self.fTorrentHashes removeObjectForKey:torrent.hashString];
            }
            [self confirmRemoveTorrents:toRemove deleteData:NO];
        });
    });
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    Toolbar* toolbar = [[Toolbar alloc] initWithIdentifier:@"TRMainToolbar"];
    toolbar.delegate = self;
    toolbar.allowsUserCustomization = YES;
    toolbar.autosavesConfiguration = YES;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    self.fWindow.toolbar = toolbar;

    self.fWindow.toolbarStyle = NSWindowToolbarStyleUnified;
    self.fWindow.titleVisibility = NSWindowTitleHidden;

    self.fWindow.delegate = self; //do manually to avoid placement issue

    [self.fWindow makeFirstResponder:self.fTableView];
    self.fWindow.excludedFromWindowsMenu = YES;

    //make window primary view in fullscreen
    self.fWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    //set table size
    BOOL const small = [self.fDefaults boolForKey:@"SmallView"];
    self.fTableView.rowHeight = small ? kRowHeightSmall : kRowHeightRegular;
    self.fTableView.usesAutomaticRowHeights = NO;
    self.fTableView.floatsGroupRows = YES;
    //self.fTableView.usesAlternatingRowBackgroundColors = !small;

    self.fWindow.movableByWindowBackground = YES;

    self.fTotalTorrentsField.cell.backgroundStyle = NSBackgroundStyleRaised;

    self.fActionButton.toolTip = NSLocalizedString(@"Shortcuts for changing global settings.", "Main window -> 1st bottom left button (action) tooltip");
    if (@available(macOS 26.0, *))
    {
        NSLayoutConstraint* constraint = [self.fActionButton.leadingAnchor constraintEqualToAnchor:self.fActionButton.superview.leadingAnchor
                                                                                          constant:16.0];
        constraint.priority = NSLayoutPriorityRequired;
        constraint.active = YES;
    }

    self.fSpeedLimitButton.toolTip = NSLocalizedString(
        @"Speed Limit overrides the total bandwidth limits with its own limits.",
        "Main window -> 2nd bottom left button (turtle) tooltip");

    self.fClearCompletedButton.toolTip = NSLocalizedString(
        @"Remove all transfers that have completed seeding.",
        "Main window -> 3rd bottom left button (remove all) tooltip");

    [self.fTableView registerForDraggedTypes:@[ kTorrentTableViewDataType ]];
    [self.fWindow registerForDraggedTypes:@[ NSPasteboardTypeFileURL, NSPasteboardTypeURL ]];

    //sort the sort menu items (localization is from strings file)
    NSMutableArray* sortMenuItems = [NSMutableArray arrayWithCapacity:7];
    NSUInteger sortMenuIndex = 0;
    BOOL foundSortItem = NO;
    for (NSMenuItem* item in self.fSortMenu.itemArray)
    {
        //assume all sort items are together and the Queue Order item is first
        if (item.action == @selector(setSort:) && item.tag != SortTagOrder)
        {
            [sortMenuItems addObject:item];
            [self.fSortMenu removeItemAtIndex:sortMenuIndex];
            foundSortItem = YES;
        }
        else
        {
            if (foundSortItem)
            {
                break;
            }
            ++sortMenuIndex;
        }
    }

    [sortMenuItems sortUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES
                                                                          selector:@selector(localizedCompare:)] ]];

    for (NSMenuItem* item in sortMenuItems)
    {
        [self.fSortMenu insertItem:item atIndex:sortMenuIndex++];
    }

    //you would think this would be called later in this method from updateUI, but it's not reached in awakeFromNib
    //this must be called after showStatusBar:
    [self.fStatusBar updateWithDownload:0.0 upload:0.0];

    // Show the window early so user sees the app is loading
    [self.fWindow makeKeyAndOrderFront:nil];

    // Process pending UI events to ensure window is displayed before heavy loading
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];

    auto* const session = self.fLib;

    //load previous transfers
    tr_ctor* ctor = tr_ctorNew(session);
    tr_ctorSetPaused(ctor, TR_FORCE, true); // paused by default; unpause below after checking state history
    auto const n_torrents = tr_sessionLoadTorrents(session, ctor);
    tr_ctorFree(ctor);

    // process the loaded torrents
    auto torrents = std::vector<tr_torrent*>{};
    torrents.resize(n_torrents);
    tr_sessionGetAllTorrents(session, std::data(torrents), std::size(torrents));
    for (auto* tor : torrents)
    {
        NSString* location;
        if (tr_torrentGetDownloadDir(tor) != NULL)
        {
            location = @(tr_torrentGetDownloadDir(tor));
        }
        Torrent* torrent = [[Torrent alloc] initWithTorrentStruct:tor location:location lib:self.fLib];
        [self.fTorrents addObject:torrent];
        self.fTorrentHashes[torrent.hashString] = torrent;
    }

    [self removeMissingDataTorrentsOnLaunch];

    // Verify torrents with zero verified bytes but not fully downloaded on launch so on-disk progress is recognized
    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.haveVerified == 0 && !torrent.allDownloaded)
        {
            [torrent resetCache];
        }
    }

    //update previous transfers state by recreating a torrent from history
    //and comparing to torrents already loaded via tr_sessionLoadTorrents
    NSString* historyFile = [self.fConfigDirectory stringByAppendingPathComponent:kTransferPlist];
    NSArray* history = [NSArray arrayWithContentsOfFile:historyFile];
    if (!history)
    {
        //old version saved transfer info in prefs file
        if ((history = [self.fDefaults arrayForKey:@"History"]))
        {
            [self.fDefaults removeObjectForKey:@"History"];
        }
    }

    if (history)
    {
        // theoretical max without doing a lot of work
        NSMutableArray* waitToStartTorrents = [NSMutableArray
            arrayWithCapacity:((history.count > 0 && !self.fPauseOnLaunch) ? history.count - 1 : 0)];

        Torrent* t = [[Torrent alloc] init];
        for (NSDictionary* historyItem in history)
        {
            NSString* hash = historyItem[@"TorrentHash"];
            if ([self.fTorrentHashes.allKeys containsObject:hash])
            {
                Torrent* torrent = self.fTorrentHashes[hash];
                [t setResumeStatusForTorrent:torrent withHistory:historyItem forcePause:self.fPauseOnLaunch];

                NSNumber* waitToStart;
                if (!self.fPauseOnLaunch && (waitToStart = historyItem[@"WaitToStart"]) && waitToStart.boolValue)
                {
                    [waitToStartTorrents addObject:torrent];
                }
            }
        }

        //now that all are loaded, let's set those in the queue to waiting
        for (Torrent* torrent in waitToStartTorrents)
        {
            [torrent startTransfer];
        }
    }

    self.fBadger = [[Badger alloc] init];

    //observe notifications
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;

    [nc addObserver:self selector:@selector(updateUI) name:@"UpdateUI" object:nil];

    [nc addObserver:self selector:@selector(torrentFinishedDownloading:) name:@"TorrentFinishedDownloading" object:nil];

    [nc addObserver:self selector:@selector(torrentRestartedDownloading:) name:@"TorrentRestartedDownloading" object:nil];

    [nc addObserver:self selector:@selector(torrentFinishedSeeding:) name:@"TorrentFinishedSeeding" object:nil];

    [nc addObserver:self selector:@selector(applyFilter) name:kTorrentDidChangeGroupNotification object:nil];

    //avoids need of setting delegate
    [nc addObserver:self selector:@selector(torrentTableViewSelectionDidChange:)
               name:NSOutlineViewSelectionDidChangeNotification
             object:self.fTableView];

    [nc addObserver:self selector:@selector(changeAutoImport) name:@"AutoImportSettingChange" object:nil];

    [nc addObserver:self selector:@selector(updateForAutoSize) name:@"AutoSizeSettingChange" object:nil];

    [nc addObserver:self selector:@selector(updateForExpandCollapse) name:@"OutlineExpandCollapse" object:nil];

    [nc addObserver:self.fWindow selector:@selector(makeKeyWindow) name:@"MakeWindowKey" object:nil];

    [nc addObserver:self selector:@selector(fullUpdateUI) name:@"UpdateTorrentsState" object:nil];

    [nc addObserver:self selector:@selector(applyFilter) name:@"ApplyFilter" object:nil];

    //open newly created torrent file
    [nc addObserver:self selector:@selector(beginCreateFile:) name:@"BeginCreateTorrentFile" object:nil];

    //open newly created torrent file
    [nc addObserver:self selector:@selector(openCreatedFile:) name:@"OpenCreatedTorrentFile" object:nil];

    [nc addObserver:self selector:@selector(applyFilter) name:@"UpdateGroups" object:nil];

    [nc addObserver:self selector:@selector(updateWindowAfterToolbarChange) name:@"ToolbarDidChange" object:nil];

    [nc addObserver:self selector:@selector(applicationWillBecomeActive:) name:NSApplicationWillBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(applicationDidResignActive:) name:NSApplicationDidResignActiveNotification object:nil];

    [self updateMainWindow];

    // Check all torrents for DJVU/FB2 files that need conversion on startup
    if ([self.fDefaults boolForKey:@"AutoConvertDjvu"])
    {
        for (Torrent* torrent in self.fTorrents)
        {
            [DjvuConverter checkAndConvertCompletedFiles:torrent];
            [Fb2Converter checkAndConvertCompletedFiles:torrent];
        }
    }

    //timer to update the interface every second
    self.fTimer = [NSTimer scheduledTimerWithTimeInterval:kUpdateUISeconds target:self selector:@selector(updateUI) userInfo:nil
                                                  repeats:YES];
    [NSRunLoop.currentRunLoop addTimer:self.fTimer forMode:NSModalPanelRunLoopMode];
    [NSRunLoop.currentRunLoop addTimer:self.fTimer forMode:NSEventTrackingRunLoopMode];

    if ([self.fDefaults boolForKey:@"InfoVisible"])
    {
        [self showInfo:nil];
    }
}

#pragma mark - NSApplicationDelegate

- (void)applicationWillFinishLaunching:(NSNotification*)notification
{
    // user notifications
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    UNNotificationAction* actionShow = [UNNotificationAction actionWithIdentifier:@"actionShow"
                                                                            title:NSLocalizedString(@"Show", "notification button")
                                                                          options:UNNotificationActionOptionForeground];
    UNNotificationCategory* categoryShow = [UNNotificationCategory categoryWithIdentifier:@"categoryShow" actions:@[ actionShow ]
                                                                        intentIdentifiers:@[]
                                                                                  options:UNNotificationCategoryOptionNone];
    [UNUserNotificationCenter.currentNotificationCenter setNotificationCategories:[NSSet setWithObject:categoryShow]];
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:(UNAuthorizationOptionSound | UNAuthorizationOptionAlert | UNAuthorizationOptionBadge)
                      completionHandler:^(BOOL /*granted*/, NSError* _Nullable error) {
                          if (error.code > 0)
                          {
                              NSLog(@"UserNotifications not configured: %@", error.localizedDescription);
                          }
                      }];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    //cover our asses
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"WarningLegal"])
    {
        NSAlert* alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"I Accept", "Legal alert -> button")];
        [alert addButtonWithTitle:NSLocalizedString(@"Quit", "Legal alert -> button")];
        alert.messageText = NSLocalizedString(@"Welcome to Transmission", "Legal alert -> title");
        alert.informativeText = NSLocalizedString(
            @"Transmission is a file-sharing program."
             " When you run a torrent, its data will be made available to others by means of upload."
             " You and you alone are fully responsible for exercising proper judgement and abiding by your local laws.",
            "Legal alert -> message");
        alert.alertStyle = NSAlertStyleInformational;

        if ([alert runModal] == NSAlertSecondButtonReturn)
        {
            exit(0);
        }

        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"WarningLegal"];
    }

    NSApp.servicesProvider = self;

    [PowerManager.shared setDelegate:self];
    [PowerManager.shared start];

    //register for dock icon drags (has to be in applicationDidFinishLaunching: to work)
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handleOpenContentsEvent:replyEvent:)
                                                     forEventClass:kCoreEventClass
                                                        andEventID:kAEOpenContents];

    //if we were opened from a user notification, do the corresponding action
    UNNotificationResponse* launchNotification = notification.userInfo[NSApplicationLaunchUserNotificationKey];
    if (launchNotification)
    {
        [self userNotificationCenter:UNUserNotificationCenter.currentNotificationCenter didReceiveNotificationResponse:launchNotification
                     withCompletionHandler:^{
                     }];
    }

    //auto importing
    [self checkAutoImportDirectory];

    //registering the Web UI to Bonjour
    if ([self.fDefaults boolForKey:@"RPC"] && [self.fDefaults boolForKey:@"RPCWebDiscovery"])
    {
        [BonjourController.defaultController startWithPort:static_cast<int>([self.fDefaults integerForKey:@"RPCPort"])];
    }

    //shamelessly ask for donations
    if ([self.fDefaults boolForKey:@"WarningDonate"])
    {
        BOOL const firstLaunch = tr_sessionGetCumulativeStats(self.fLib).sessionCount <= 1;

        NSDate* lastDonateDate = [self.fDefaults objectForKey:@"DonateAskDate"];
        BOOL const timePassed = !lastDonateDate || (-1 * lastDonateDate.timeIntervalSinceNow) >= kDonateNagTime;

        if (!firstLaunch && timePassed)
        {
            [self.fDefaults setObject:[NSDate date] forKey:@"DonateAskDate"];

            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = NSLocalizedString(@"Support open-source indie software", "Donation beg -> title");

            NSString* donateMessage = [NSString
                stringWithFormat:@"%@\n\n%@",
                                 NSLocalizedString(
                                     @"Transmission is a full-featured torrent application."
                                      " A lot of time and effort have gone into development, coding, and refinement."
                                      " If you enjoy using it, please consider showing your love with a donation.",
                                     "Donation beg -> message"),
                                 NSLocalizedString(@"Donate or not, there will be no difference to your torrenting experience.", "Donation beg -> message")];

            alert.informativeText = donateMessage;
            alert.alertStyle = NSAlertStyleInformational;

            [alert addButtonWithTitle:[NSLocalizedString(@"Donate", "Donation beg -> button") stringByAppendingEllipsis]];
            NSButton* noDonateButton = [alert addButtonWithTitle:NSLocalizedString(@"Nope", "Donation beg -> button")];
            noDonateButton.keyEquivalent = @"\e"; //escape key

            // hide the "don't show again" check the first time - give them time to try the app
            BOOL const allowNeverAgain = lastDonateDate != nil;
            alert.showsSuppressionButton = allowNeverAgain;
            if (allowNeverAgain)
            {
                alert.suppressionButton.title = NSLocalizedString(@"Don't bug me about this ever again.", "Donation beg -> button");
            }

            NSInteger const donateResult = [alert runModal];
            if (donateResult == NSAlertFirstButtonReturn)
            {
                [self linkDonate:self];
            }

            if (allowNeverAgain)
            {
                [self.fDefaults setBool:(alert.suppressionButton.state != NSControlStateValueOn) forKey:@"WarningDonate"];
            }
        }
    }

    // Preload AppKit Text Input UI (initTUINSCursorUIController) so first click in search field
    // does not block main thread on dlopen (macOS hang report 2026-02: NSTextField becomeFirstResponder).
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf preloadSearchFieldTextInput];
    });
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)app hasVisibleWindows:(BOOL)visibleWindows
{
    NSWindow* mainWindow = NSApp.mainWindow;
    if (!mainWindow || !mainWindow.visible)
    {
        [self.fWindow makeKeyAndOrderFront:nil];
        [self scheduleProcessPriorityUpdate];
    }

    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
    if (self.fQuitRequested || ![self.fDefaults boolForKey:@"CheckQuit"])
    {
        return NSTerminateNow;
    }

    NSUInteger active = 0, downloading = 0;
    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.active && !torrent.stalled)
        {
            active++;
            if (!torrent.allDownloaded)
            {
                downloading++;
            }
        }
    }

    BOOL preventedByTransfer = [self.fDefaults boolForKey:@"CheckQuitDownloading"] ? downloading > 0 : active > 0;

    if (!preventedByTransfer)
    {
        return NSTerminateNow;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Are you sure you want to quit?", "Confirm Quit panel -> title");
    alert.informativeText = active == 1 ?
        NSLocalizedString(
            @"There is an active transfer that will be paused on quit."
             " The transfer will automatically resume on the next launch.",
            "Confirm Quit panel -> message") :
        [NSString localizedStringWithFormat:NSLocalizedString(
                                                @"There are %lu active transfers that will be paused on quit."
                                                 " The transfers will automatically resume on the next launch.",
                                                "Confirm Quit panel -> message"),
                                            active];
    [alert addButtonWithTitle:NSLocalizedString(@"Quit", "Confirm Quit panel -> button")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "Confirm Quit panel -> button")];
    alert.showsSuppressionButton = YES;

    [alert beginSheetModalForWindow:self.fWindow completionHandler:^(NSModalResponse returnCode) {
        if (alert.suppressionButton.state == NSControlStateValueOn)
        {
            [self.fDefaults setBool:NO forKey:@"CheckQuit"];
        }
        [NSApp replyToApplicationShouldTerminate:returnCode == NSAlertFirstButtonReturn];
    }];

    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
    self.fQuitting = YES;

    // Switch to normal priority for faster shutdown
    [self applyNormalPriority];

    [PowerManager.shared stop];

    //stop the Bonjour service
    if (BonjourController.defaultControllerExists)
    {
        [BonjourController.defaultController stop];
    }

    //stop blocklist download
    if (BlocklistDownloader.isRunning)
    {
        [[BlocklistDownloader downloader] cancelDownload];
    }

    //stop timers and notification checking
    [NSNotificationCenter.defaultCenter removeObserver:self];

    [self.fTimer invalidate];

    if (self.fAutoImportTimer)
    {
        if (self.fAutoImportTimer.valid)
        {
            [self.fAutoImportTimer invalidate];
        }
    }

    //remove all torrent downloads
    [self.fSession invalidateAndCancel];

    //remember window states
    [self.fDefaults setBool:self.fInfoController.window.visible forKey:@"InfoVisible"];

    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible)
    {
        [[QLPreviewPanel sharedPreviewPanel] updateController];
    }

    // close all windows
    for (NSWindow* window in NSApp.windows)
    {
        [window close];
    }

    // clear the badge
    [self.fBadger updateBadgeWithDownload:0 upload:0];

    //save history
    [self updateTorrentHistory];
    [self.fTableView saveCollapsedGroups];

    _fileWatcherQueue = nil;

    //complete cleanup: short timeout for stop announces to responsive trackers
    tr_sessionClose(self.fLib, 1.0);
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app
{
    return YES;
}

- (void)applicationWillBecomeActive:(NSNotification*)notification
{
    [self scheduleProcessPriorityUpdate];
}

- (void)applicationDidBecomeActive:(NSNotification*)notification
{
    [self scheduleProcessPriorityUpdate];
}

- (void)applicationDidResignActive:(NSNotification*)notification
{
    [self scheduleProcessPriorityUpdate];
}

#pragma mark - NSWindowDelegate

- (BOOL)windowShouldClose:(NSWindow*)window
{
    if (window != self.fWindow)
    {
        return YES;
    }

    // Check if any torrent is actively downloading
    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.downloading)
        {
            return YES; // Allow normal close (window hides)
        }
    }

    // No torrents downloading - quit the app instead
    [NSApp terminate:self];
    return NO;
}

- (void)windowDidMiniaturize:(NSNotification*)notification
{
    if (notification.object == self.fWindow)
    {
        self.fWindowMiniaturized = YES;
        [self scheduleProcessPriorityUpdate];
    }
}

- (void)windowDidDeminiaturize:(NSNotification*)notification
{
    if (notification.object == self.fWindow)
    {
        self.fWindowMiniaturized = NO;
        [self scheduleProcessPriorityUpdate];
    }
}

#pragma mark -

- (void)scheduleProcessPriorityUpdate
{
    BOOL const shouldUseBackground = !NSApp.active || self.fWindowMiniaturized;

    if (shouldUseBackground)
    {
        // Apply background priority immediately
        [self applyLowPriority];
    }
    else
    {
        // Restore normal priority immediately
        [self applyNormalPriority];
    }
}

- (void)restorePriorityForUserInteraction
{
    [self.fLowPriorityTimer invalidate];
    self.fLowPriorityTimer = nil;
    [self applyNormalPriority];
}

- (void)applyLowPriority
{
    if (self.fUsingBackgroundPriority)
    {
        return;
    }

    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_THROTTLE);
    self.fUsingBackgroundPriority = YES;
}

- (void)applyNormalPriority
{
    if (!self.fUsingBackgroundPriority)
    {
        return;
    }

    setpriority(PRIO_DARWIN_PROCESS, 0, 0);
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_DEFAULT);
    self.fUsingBackgroundPriority = NO;
}

- (tr_session*)sessionHandle
{
    return self.fLib;
}

- (void)handleOpenContentsEvent:(NSAppleEventDescriptor*)event replyEvent:(NSAppleEventDescriptor*)replyEvent
{
    NSString* urlString = nil;

    NSAppleEventDescriptor* directObject = [event paramDescriptorForKeyword:keyDirectObject];
    if (directObject.descriptorType == typeAEList)
    {
        for (NSInteger i = 1; i <= directObject.numberOfItems; i++)
        {
            if ((urlString = [directObject descriptorAtIndex:i].stringValue))
            {
                break;
            }
        }
    }
    else
    {
        urlString = directObject.stringValue;
    }

    if (urlString)
    {
        [self openURL:urlString];
    }
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(nonnull NSURLSession*)session
              dataTask:(nonnull NSURLSessionDataTask*)dataTask
    didReceiveResponse:(nonnull NSURLResponse*)response
     completionHandler:(nonnull void (^)(NSURLSessionResponseDisposition))completionHandler
{
    NSString* suggestedName = response.suggestedFilename;
    if ([suggestedName.pathExtension caseInsensitiveCompare:@"torrent"] == NSOrderedSame)
    {
        completionHandler(NSURLSessionResponseBecomeDownload);
        return;
    }
    completionHandler(NSURLSessionResponseCancel);

    NSString* message = [NSString
        stringWithFormat:NSLocalizedString(@"It appears that the file \"%@\" from %@ is not a torrent file.", "Download not a torrent -> message"),
                         suggestedName,
                         dataTask.originalRequest.URL.absoluteString.stringByRemovingPercentEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", "Download not a torrent -> button")];
        alert.messageText = NSLocalizedString(@"Torrent download failed", "Download not a torrent -> title");
        alert.informativeText = message;
        [alert runModal];
    });
}

- (void)URLSession:(nonnull NSURLSession*)session
                 dataTask:(nonnull NSURLSessionDataTask*)dataTask
    didBecomeDownloadTask:(nonnull NSURLSessionDownloadTask*)downloadTask
{
    // Required delegate method to proceed with  NSURLSessionResponseBecomeDownload.
    // nothing to do
}

- (void)URLSession:(nonnull NSURLSession*)session
                 downloadTask:(nonnull NSURLSessionDownloadTask*)downloadTask
    didFinishDownloadingToURL:(nonnull NSURL*)location
{
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:downloadTask.response.suggestedFilename.lastPathComponent];
    NSError* error;
    [NSFileManager.defaultManager moveItemAtPath:location.path toPath:path error:&error];
    if (error)
    {
        [self URLSession:session task:downloadTask didCompleteWithError:error];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self openFiles:@[ path ] addType:AddTypeURL forcePath:nil];

        //delete the torrent file after opening
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    });
}

- (void)URLSession:(nonnull NSURLSession*)session
                    task:(nonnull NSURLSessionTask*)task
    didCompleteWithError:(nullable NSError*)error
{
    if (!error || error.code == NSURLErrorCancelled)
    {
        // no errors or we already displayed an alert
        return;
    }

    NSString* urlString = task.currentRequest.URL.absoluteString;
    if ([urlString rangeOfString:@"magnet:" options:(NSAnchoredSearch | NSCaseInsensitiveSearch)].location != NSNotFound)
    {
        // originalRequest was a redirect to a magnet
        [self performSelectorOnMainThread:@selector(openMagnet:) withObject:urlString waitUntilDone:NO];
        return;
    }

    NSString* message = [NSString
        stringWithFormat:NSLocalizedString(@"The torrent could not be downloaded from %@: %@.", "Torrent download failed -> message"),
                         task.originalRequest.URL.absoluteString.stringByRemovingPercentEncoding,
                         error.localizedDescription];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", "Torrent download failed -> button")];
        alert.messageText = NSLocalizedString(@"Torrent download failed", "Torrent download error -> title");
        alert.informativeText = message;
        [alert runModal];
    });
}

#pragma mark -

- (void)application:(NSApplication*)app openFiles:(NSArray<NSString*>*)filenames
{
    [self openFiles:filenames addType:AddTypeManual forcePath:nil];
}

- (void)insertTorrentAtTop:(Torrent*)torrent
{
    [self.fTorrents insertObject:torrent atIndex:0];
    NSUInteger queuePosition = 0;
    for (Torrent* existing in self.fTorrents)
    {
        existing.queuePosition = queuePosition++;
    }

    // Keep on-screen order in sync when sorting by queue
    if ([[self.fDefaults stringForKey:@"Sort"] isEqualToString:SortTypeOrder])
    {
        [self sortTorrentsCallUpdates:YES includeQueueOrder:YES];
    }
}

- (void)createFile:(id)sender
{
    [CreatorWindowController createTorrentFile:self.fLib];
}

- (void)resumeSelectedTorrents:(id)sender
{
    [self resumeTorrents:self.fTableView.selectedTorrents];
}

- (void)resumeAllTorrents:(id)sender
{
    NSMutableArray<Torrent*>* torrents = [NSMutableArray arrayWithCapacity:self.fTorrents.count];

    for (Torrent* torrent in self.fTorrents)
    {
        if (!torrent.finishedSeeding)
        {
            [torrents addObject:torrent];
        }
    }

    [self resumeTorrents:torrents];
}

- (void)resumeSelectedTorrentsNoWait:(id)sender
{
    [self resumeTorrentsNoWait:self.fTableView.selectedTorrents];
}

- (void)resumeWaitingTorrents:(id)sender
{
    NSMutableArray<Torrent*>* torrents = [NSMutableArray arrayWithCapacity:self.fTorrents.count];

    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.waitingToStart)
        {
            [torrents addObject:torrent];
        }
    }

    [self resumeTorrentsNoWait:torrents];
}

- (void)stopSelectedTorrents:(id)sender
{
    [self stopTorrents:self.fTableView.selectedTorrents];
}

- (void)stopAllTorrents:(id)sender
{
    [self stopTorrents:self.fTorrents];
}

- (void)showPreferenceWindow:(id)sender
{
    // Force nib loading and awakeFromNib
    [_prefsController window];
    NSWindow* window = _prefsController.window;
    if (!window.visible)
    {
        [window center];
    }

    [window makeKeyAndOrderFront:nil];
}

- (void)showAboutWindow:(id)sender
{
    [AboutWindowController.aboutController showWindow:nil];
}

- (void)showInfo:(id)sender
{
    [self.fInfoController updateInfoStats];
    [self.fInfoController.window orderFront:nil];

    if (self.fInfoController.canQuickLook && [QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible)
    {
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
    }

    [self.fWindow.toolbar validateVisibleItems];
}

- (void)resetInfo
{
    [self.fInfoController setInfoForTorrents:self.fTableView.selectedTorrents];

    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].visible)
    {
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
    }
}

- (void)setInfoTab:(id)sender
{
    if (sender == self.fNextInfoTabItem)
    {
        [self.fInfoController setNextTab];
    }
    else
    {
        [self.fInfoController setPreviousTab];
    }
}

- (MessageWindowController*)messageWindowController
{
    if (!self.fMessageController)
    {
        self.fMessageController = [[MessageWindowController alloc] init];
    }

    return self.fMessageController;
}

- (void)showMessageWindow:(id)sender
{
    [self.messageWindowController showWindow:nil];
}

- (void)showStatsWindow:(id)sender
{
    [StatsWindowController.statsWindow showWindow:nil];
}

#pragma mark -

- (void)updateTorrentHistory
{
    NSMutableArray* history = [NSMutableArray arrayWithCapacity:self.fTorrents.count];

    for (Torrent* torrent in self.fTorrents)
    {
        [history addObject:torrent.history];
        self.fTorrentHashes[torrent.hashString] = torrent;
    }

    NSString* historyFile = [self.fConfigDirectory stringByAppendingPathComponent:kTransferPlist];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [history writeToFile:historyFile atomically:YES];
    });
}

- (void)switchFilter:(id)sender
{
    [self.fFilterBar switchFilter:sender == self.fNextFilterItem];
}

- (IBAction)showGlobalPopover:(id)sender
{
    if (self.fGlobalPopoverShown)
    {
        return;
    }

    NSPopover* popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    GlobalOptionsPopoverViewController* viewController = [[GlobalOptionsPopoverViewController alloc] initWithHandle:self.fLib];
    popover.contentViewController = viewController;
    popover.delegate = self;

    NSView* senderView = sender;
    CGFloat width = NSWidth(senderView.frame);

    if (NSMinX(self.fWindow.frame) < width || NSMaxX(self.fWindow.screen.visibleFrame) - NSMinX(self.fWindow.frame) < width * 2)
    {
        // Ugly hack to hide NSPopover arrow.
        self.fPositioningView = [[NSView alloc] initWithFrame:senderView.bounds];
        self.fPositioningView.identifier = @"positioningView";
        [senderView addSubview:self.fPositioningView];
        [popover showRelativeToRect:self.fPositioningView.bounds ofView:self.fPositioningView preferredEdge:NSMaxYEdge];
        self.fPositioningView.bounds = NSOffsetRect(self.fPositioningView.bounds, 0, NSHeight(self.fPositioningView.bounds));
    }
    else
    {
        [popover showRelativeToRect:senderView.bounds ofView:senderView preferredEdge:NSMaxYEdge];
    }
}

//don't show multiple popovers when clicking the gear button repeatedly
- (void)popoverWillShow:(NSNotification*)notification
{
    self.fGlobalPopoverShown = YES;
}

- (void)popoverDidClose:(NSNotification*)notification
{
    [self.fPositioningView removeFromSuperview];
    self.fGlobalPopoverShown = NO;
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
    if (menu == self.fGroupsSetMenu || menu == self.fGroupsSetContextMenu)
    {
        [menu removeAllItems];

        NSMenu* groupMenu = [GroupsController.groups groupMenuWithTarget:self action:@selector(setGroup:) isSmall:NO];

        NSInteger const groupMenuCount = groupMenu.numberOfItems;
        for (NSInteger i = 0; i < groupMenuCount; i++)
        {
            NSMenuItem* item = [groupMenu itemAtIndex:0];
            [groupMenu removeItemAtIndex:0];
            [menu addItem:item];
        }
    }
    else if (menu == self.fShareMenu || menu == self.fShareContextMenu)
    {
        [menu removeAllItems];

        for (NSMenuItem* item in ShareTorrentFileHelper.sharedHelper.menuItems)
        {
            [menu addItem:item];
        }
    }
}

- (void)setGroup:(id)sender
{
    for (Torrent* torrent in self.fTableView.selectedTorrents)
    {
        [self.fTableView removeCollapsedGroup:torrent.groupValue]; //remove old collapsed group

        [torrent setGroupValue:((NSMenuItem*)sender).tag determinationType:TorrentDeterminationUserSpecified];
    }

    [self applyFilter];
    [self updateUI];
    [self updateTorrentHistory];
}

- (void)toggleSpeedLimit:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"SpeedLimit"] forKey:@"SpeedLimit"];
    [self speedLimitChanged:sender];
}

- (void)speedLimitChanged:(id)sender
{
    tr_sessionUseAltSpeed(self.fLib, [self.fDefaults boolForKey:@"SpeedLimit"]);
    [self.fStatusBar updateSpeedFieldsToolTips];
}

- (void)altSpeedToggledCallbackIsLimited:(NSDictionary*)dict
{
    BOOL const isLimited = [dict[@"Active"] boolValue];

    [self.fDefaults setBool:isLimited forKey:@"SpeedLimit"];
    [self.fStatusBar updateSpeedFieldsToolTips];

    if (![dict[@"ByUser"] boolValue])
    {
        NSString* title = isLimited ? NSLocalizedString(@"Speed Limit Auto Enabled", "notification title") :
                                      NSLocalizedString(@"Speed Limit Auto Disabled", "notification title");
        NSString* body = NSLocalizedString(@"Bandwidth settings changed", "notification description");

        NSString* identifier = @"Bandwidth settings changed";
        UNMutableNotificationContent* content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = body;

        UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
    }
}

- (void)sound:(NSSound*)sound didFinishPlaying:(BOOL)finishedPlaying
{
    self.fSoundPlaying = NO;
}

- (void)VDKQueue:(VDKQueue*)queue receivedNotification:(NSString*)notification forPath:(NSString*)fpath
{
    //don't assume that just because we're watching for write notification, we'll only receive write notifications

    if (![self.fDefaults boolForKey:@"AutoImport"] || ![self.fDefaults stringForKey:@"AutoImportDirectory"])
    {
        return;
    }

    if (self.fAutoImportTimer.valid)
    {
        [self.fAutoImportTimer invalidate];
    }

    //check again in 10 seconds in case torrent file wasn't complete
    self.fAutoImportTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self
                                                           selector:@selector(checkAutoImportDirectory)
                                                           userInfo:nil
                                                            repeats:NO];

    [self checkAutoImportDirectory];
}

- (void)changeAutoImport
{
    if (self.fAutoImportTimer.valid)
    {
        [self.fAutoImportTimer invalidate];
    }
    self.fAutoImportTimer = nil;

    self.fAutoImportedNames = nil;

    [self checkAutoImportDirectory];
}

- (void)checkAutoImportDirectory
{
    NSString* path;
    if (![self.fDefaults boolForKey:@"AutoImport"] || !(path = [self.fDefaults stringForKey:@"AutoImportDirectory"]))
    {
        return;
    }

    path = path.stringByExpandingTildeInPath;

    NSArray<NSString*>* importedNames;
    if (!(importedNames = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL]))
    {
        return;
    }

    //only check files that have not been checked yet
    NSMutableArray* newNames = [importedNames mutableCopy];

    if (self.fAutoImportedNames)
    {
        [newNames removeObjectsInArray:self.fAutoImportedNames];
    }
    else
    {
        self.fAutoImportedNames = [[NSMutableArray alloc] init];
    }
    [self.fAutoImportedNames setArray:importedNames];

    for (NSString* file in newNames)
    {
        if ([file hasPrefix:@"."])
        {
            continue;
        }

        NSString* fullFile = [path stringByAppendingPathComponent:file];
        NSURL* fileURL = [NSURL fileURLWithPath:fullFile];
        NSString* contentType = nil;
        [fileURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:NULL];

        if (!([contentType isEqualToString:@"org.bittorrent.torrent"] || [fullFile.pathExtension caseInsensitiveCompare:@"torrent"] == NSOrderedSame))
        {
            continue;
        }

        NSDictionary<NSFileAttributeKey, id>* fileAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:fullFile
                                                                                                              error:nil];
        if (fileAttributes.fileSize == 0)
        {
            // Workaround for Firefox downloads happening in two steps: first time being an empty file
            [self.fAutoImportedNames removeObject:file];
            continue;
        }

        auto metainfo = tr_torrent_metainfo{};
        if (!metainfo.parse_torrent_file(fullFile.UTF8String))
        {
            continue;
        }

        [self openFiles:@[ fullFile ] addType:AddTypeAuto forcePath:nil];

        NSString* notificationTitle = NSLocalizedString(@"Torrent File Auto Added", "notification title");

        NSString* identifier = [@"Torrent File Auto Added " stringByAppendingString:file];
        UNMutableNotificationContent* content = [UNMutableNotificationContent new];
        content.title = notificationTitle;
        content.body = file;

        UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
    }
}

- (void)beginCreateFile:(NSNotification*)notification
{
    if (![self.fDefaults boolForKey:@"AutoImport"])
    {
        return;
    }

    NSString *location = ((NSURL*)notification.object).path, *path = [self.fDefaults stringForKey:@"AutoImportDirectory"];

    if (location && path && [location.stringByDeletingLastPathComponent.stringByExpandingTildeInPath isEqualToString:path.stringByExpandingTildeInPath])
    {
        [self.fAutoImportedNames addObject:location.lastPathComponent];
    }
}

- (void)torrentTableViewSelectionDidChange:(NSNotification*)notification
{
    [self resetInfo];
    [self.fWindow.toolbar validateVisibleItems];
}

- (void)toggleSmallView:(id)sender
{
    BOOL makeSmall = ![self.fDefaults boolForKey:@"SmallView"];
    [self.fDefaults setBool:makeSmall forKey:@"SmallView"];

    //self.fTableView.usesAlternatingRowBackgroundColors = !makeSmall;

    self.fTableView.rowHeight = makeSmall ? kRowHeightSmall : kRowHeightRegular;

    [self.fTableView beginUpdates];
    [self.fTableView
        noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.fTableView.numberOfRows)]];
    [self.fTableView endUpdates];

    [self reloadTransfersTableContent];
    [self updateForAutoSize];
}

- (void)togglePiecesBar:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"PiecesBar"] forKey:@"PiecesBar"];
    [self.fTableView togglePiecesBar];
}

- (void)toggleAvailabilityBar:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"DisplayProgressBarAvailable"] forKey:@"DisplayProgressBarAvailable"];
    [self.fTableView display];
}

- (void)toggleShowContentButtons:(id)sender
{
    [self.fDefaults setBool:![self.fDefaults boolForKey:@"ShowContentButtons"] forKey:@"ShowContentButtons"];
    [self.fTableView refreshContentButtonsVisibility];
    [self refreshVisibleTransferRows];
    [self updateForAutoSize];
}

- (void)toggleStatusBar:(id)sender
{
    BOOL const show = self.fStatusBar == nil || self.fStatusBar.isHidden;
    [self.fDefaults setBool:show forKey:@"StatusBar"];
    [self updateMainWindow];
}

- (void)toggleFilterBar:(id)sender
{
    BOOL const show = self.fFilterBar == nil || self.fFilterBar.isHidden;

    if (!show)
    {
        [self.fFilterBar reset];
    }

    [self.fDefaults setBool:show forKey:@"FilterBar"];
    [self updateMainWindow];

    if (show)
    {
        [self focusFilterField];
    }
}

- (IBAction)toggleToolbarShown:(id)sender
{
    [self.fWindow toggleToolbarShown:sender];
}

- (void)showToolbarShare:(id)sender
{
    NSParameterAssert([sender isKindOfClass:[NSButton class]]);
    NSButton* senderButton = sender;

    NSSharingServicePicker* picker = [[NSSharingServicePicker alloc] initWithItems:ShareTorrentFileHelper.sharedHelper.shareTorrentURLs];
    picker.delegate = self;

    [picker showRelativeToRect:senderButton.bounds ofView:senderButton preferredEdge:NSMinYEdge];
}

- (id<NSSharingServiceDelegate>)sharingServicePicker:(NSSharingServicePicker*)sharingServicePicker
                           delegateForSharingService:(NSSharingService*)sharingService
{
    return self;
}

- (NSWindow*)sharingService:(NSSharingService*)sharingService
    sourceWindowForShareItems:(NSArray*)items
          sharingContentScope:(NSSharingContentScope*)sharingContentScope
{
    return self.fWindow;
}

- (void)systemWillSleep
{
    //stop all transfers (since some are active) before going to sleep and remember to resume when we wake up
    BOOL anyActive = NO;
    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.active)
        {
            anyActive = YES;
        }
        [torrent sleep]; //have to call on all, regardless if they are active
    }

    //if there are any running transfers, wait 15 seconds for them to stop
    if (anyActive)
    {
        sleep(15);
    }
}

- (void)systemDidWakeUp
{
    //resume sleeping transfers after we wake up
    for (Torrent* torrent in self.fTorrents)
    {
        [torrent wakeUp];
    }
}

- (NSMenu*)applicationDockMenu:(NSApplication*)sender
{
    if (self.fQuitting)
    {
        return nil;
    }

    NSUInteger seeding = 0, downloading = 0;
    for (Torrent* torrent in self.fTorrents)
    {
        if (torrent.seeding)
        {
            seeding++;
        }
        else if (torrent.active)
        {
            downloading++;
        }
    }

    NSMenu* menu = [[NSMenu alloc] init];

    if (seeding > 0)
    {
        NSString* title = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu Seeding", "Dock item - Seeding"), seeding];
        [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    }

    if (downloading > 0)
    {
        NSString* title = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu Downloading", "Dock item - Downloading"), downloading];
        [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    }

    if (seeding > 0 || downloading > 0)
    {
        [menu addItem:[NSMenuItem separatorItem]];
    }

    [menu addItemWithTitle:NSLocalizedString(@"Pause All", "Dock item") action:@selector(stopAllTorrents:) keyEquivalent:@""];
    [menu addItemWithTitle:NSLocalizedString(@"Resume All", "Dock item") action:@selector(resumeAllTorrents:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"Speed Limit", "Dock item") action:@selector(toggleSpeedLimit:) keyEquivalent:@""];

    return menu;
}

- (void)toggleQuickLook:(id)sender
{
    if ([QLPreviewPanel sharedPreviewPanel].visible)
    {
        [[QLPreviewPanel sharedPreviewPanel] orderOut:nil];
    }
    else
    {
        [[QLPreviewPanel sharedPreviewPanel] makeKeyAndOrderFront:nil];
    }
}

- (void)linkHomepage:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kWebsiteURL]];
}

- (void)linkForums:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kForumURL]];
}

- (void)linkGitHub:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kGithubURL]];
}

- (void)linkDonate:(id)sender
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kDonateURL]];
}

@end
#pragma clang diagnostic pop

@implementation Controller (SUUpdaterDelegate)

- (void)updaterWillRelaunchApplication:(SUUpdater*)updater
{
    self.fQuitRequested = YES;
}

- (nullable id<SUVersionComparison>)versionComparatorForUpdater:(SUUpdater*)updater
{
    return [VersionComparator new];
}

@end
