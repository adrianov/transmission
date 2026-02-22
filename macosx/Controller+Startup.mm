// This file Copyright © Transmission authors and contributors.
// It may be used under the MIT (SPDX: MIT) license.
// License text can be found in the licenses/ folder.

// Startup checks: KeRanger ransomware cleanup (2.90 legacy). Called from +[Controller initialize].

#import "Controller.h"

// 2.90 was infected with ransomware which we now check for and attempt to remove
static void removeKeRangerRansomware(void)
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

@implementation Controller (Startup)

+ (void)runStartupChecks
{
    removeKeRangerRansomware();
}

@end
