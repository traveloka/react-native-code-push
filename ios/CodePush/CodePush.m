#if __has_include(<React/RCTAssert.h>)
#import <React/RCTAssert.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTRootView.h>
#import <React/RCTUtils.h>
#else // back compatibility for RN version < 0.40
#import "RCTAssert.h"
#import "RCTBridgeModule.h"
#import "RCTConvert.h"
#import "RCTEventDispatcher.h"
#import "RCTRootView.h"
#import "RCTUtils.h"
#endif

#import "CodePush.h"

@interface CodePush () <RCTBridgeModule, RCTFrameUpdateObserver>
@property(nonatomic, assign) BOOL hasResumeListener;
@property(nonatomic, assign) BOOL isFirstRunAfterUpdate;
@property(nonatomic, assign) int minimumBackgroundDuration;
@property(nonatomic, strong) NSDate *lastResignedDate;
@property(nonatomic, assign) CodePushInstallMode installMode;
@property(nonatomic, strong) NSTimer *appSuspendTimer;

// Used to coordinate the dispatching of download progress events to JS.
@property(nonatomic, assign) long long latestExpectedContentLength;
@property(nonatomic, assign) long long latestReceivedConentLength;
@property(nonatomic, assign) BOOL didUpdateProgress;

@property(nonatomic, strong) CodePushConfig *codePushConfig;
@property(nonatomic, strong) CodePushPackage *codePushPackage;
@property(nonatomic, strong) CodePushTelemetryManager *codePushTelemetryManager;

// These values are used to save the NS bundle, name, extension and subdirectory
// for the JS bundle in the binary.
@property(nonatomic, strong) NSBundle *bundleResourceBundle;
@property(nonatomic, strong) NSString *bundleResourceExtension;
@property(nonatomic, strong) NSString *bundleResourceName;
@property(nonatomic, strong) NSString *bundleResourceSubdirectory;

@property(nonatomic, assign) BOOL isRunningBinaryVersion;
@property(nonatomic, assign) BOOL needToReportRollback;
@end

@implementation CodePush

RCT_EXPORT_MODULE()

#pragma mark - Private constants

// CodePush Key on Info.plist
static NSString *const CODEPUSH_KEY = @"CodePushDeploymentKey";

// These constants represent emitted events
static NSString *const DownloadProgressEvent = @"CodePushDownloadProgress";

// These constants represent valid deployment statuses
static NSString *const DeploymentFailed = @"DeploymentFailed";
static NSString *const DeploymentSucceeded = @"DeploymentSucceeded";

// These keys represent the names we use to store data in NSUserDefaults
static NSString *const FailedUpdatesKey = @"CODE_PUSH_FAILED_UPDATES";
static NSString *const PendingUpdateKey = @"CODE_PUSH_PENDING_UPDATE";

// These keys are already "namespaced" by the PendingUpdateKey, so
// their values don't need to be obfuscated to prevent collision with app data
static NSString *const PendingUpdateHashKey = @"hash";
static NSString *const PendingUpdateIsLoadingKey = @"isLoading";

// These keys are used to inspect/augment the metadata
// that is associated with an update's package.
static NSString *const AppVersionKey = @"appVersion";
static NSString *const BinaryBundleDateKey = @"binaryDate";
static NSString *const PackageHashKey = @"packageHash";
static NSString *const PackageIsPendingKey = @"isPending";

#pragma mark - Static variables

static BOOL testConfigurationFlag = NO;

// These keys represent the names we use to store information about the latest rollback
static NSString *const LatestRollbackInfoKey = @"LATEST_ROLLBACK_INFO";
static NSString *const LatestRollbackPackageHashKey = @"packageHash";
static NSString *const LatestRollbackTimeKey = @"time";
static NSString *const LatestRollbackCountKey = @"count";

+ (CodePush *)sharedInstance {
    static CodePush *sharedInstance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *config = @{
          @"deploymentKey": [[NSBundle mainBundle] objectForInfoDictionaryKey:CODEPUSH_KEY]
        };
        sharedInstance = [[CodePush alloc] initWithConfig:config];
    });
    return sharedInstance;
}

- (instancetype)initWithConfig:(NSDictionary *)config
{
    if (self = [self init]) {
        CPLog(@"initWithConfig: %@", config);
        
        // Use the mainBundle by default.
        _bundleResourceBundle = [NSBundle mainBundle];
        
        _isRunningBinaryVersion = NO;
        _needToReportRollback = NO;
        
        NSString *deploymentKey = [config objectForKey:@"deploymentKey"];
        _codePushConfig = [[CodePushConfig alloc] initWithDeploymentKey:deploymentKey];
    }
    return self;
}

#pragma mark - Public Obj-C API

- (NSURL *)binaryBundleURL
{
    return [_bundleResourceBundle URLForResource:_bundleResourceName
                                  withExtension:_bundleResourceExtension
                                   subdirectory:_bundleResourceSubdirectory];
}

- (NSString *)bundleAssetsPath
{
    NSString *resourcePath = [_bundleResourceBundle resourcePath];
    if (_bundleResourceSubdirectory) {
        resourcePath = [resourcePath stringByAppendingPathComponent:_bundleResourceSubdirectory];
    }

    return [resourcePath stringByAppendingPathComponent:[CodePushUpdateUtils assetsFolderName]];
}

- (NSString *)getBundleName
{
    return _bundleResourceName;
}

- (NSURL *)bundleURL
{
    return [self bundleURLForResource:_bundleResourceName
                        withExtension:_bundleResourceExtension
                         subdirectory:_bundleResourceSubdirectory
                               bundle:_bundleResourceBundle];
}

- (NSURL *)bundleURLForResource:(NSString *)resourceName
{
    return [self bundleURLForResource:resourceName
                        withExtension:_bundleResourceExtension
                         subdirectory:_bundleResourceSubdirectory
                               bundle:_bundleResourceBundle];
}

- (NSURL *)bundleURLForResource:(NSString *)resourceName
                  withExtension:(NSString *)resourceExtension
{
    return [self bundleURLForResource:resourceName
                        withExtension:resourceExtension
                         subdirectory:_bundleResourceSubdirectory
                               bundle:_bundleResourceBundle];
}

- (NSURL *)bundleURLForResource:(NSString *)resourceName
                  withExtension:(NSString *)resourceExtension
                   subdirectory:(NSString *)resourceSubdirectory
{
    return [self bundleURLForResource:resourceName
                        withExtension:resourceExtension
                         subdirectory:resourceSubdirectory
                               bundle:_bundleResourceBundle];
}

- (NSURL *)bundleURLForResource:(NSString *)resourceName
                  withExtension:(NSString *)resourceExtension
                   subdirectory:(NSString *)resourceSubdirectory
                         bundle:(NSBundle *)resourceBundle
{
    _bundleResourceName = resourceName;
    _bundleResourceExtension = resourceExtension;
    _bundleResourceSubdirectory = resourceSubdirectory;
    _bundleResourceBundle = resourceBundle;

    _codePushPackage = [[CodePushPackage alloc] initWithBundleName:_bundleResourceName];
    _codePushTelemetryManager = [[CodePushTelemetryManager alloc] initWithBundleName:_bundleResourceName];
    [self ensureBinaryBundleExists];

    NSString *logMessageFormat = @"Loading JS bundle from %@";

    NSError *error;
    NSString *packageFile = [_codePushPackage getCurrentPackageBundlePath:&error];
    NSURL *binaryBundleURL = [self binaryBundleURL];

    if (error || !packageFile) {
        CPLog(logMessageFormat, binaryBundleURL);
        _isRunningBinaryVersion = YES;
        return binaryBundleURL;
    }

    NSString *binaryAppVersion = [_codePushConfig appVersion];
    NSDictionary *currentPackageMetadata = [_codePushPackage getCurrentPackage:&error];
    if (error || !currentPackageMetadata) {
        CPLog(logMessageFormat, binaryBundleURL);
        _isRunningBinaryVersion = YES;
        return binaryBundleURL;
    }

    NSString *packageDate = [currentPackageMetadata objectForKey:BinaryBundleDateKey];
    NSString *packageAppVersion = [currentPackageMetadata objectForKey:AppVersionKey];

    if ([[CodePushUpdateUtils modifiedDateStringOfFileAtURL:binaryBundleURL] isEqualToString:packageDate] && ([CodePush isUsingTestConfiguration] ||[binaryAppVersion isEqualToString:packageAppVersion])) {
        // Return package file because it is newer than the app store binary's JS bundle
        NSURL *packageUrl = [[NSURL alloc] initFileURLWithPath:packageFile];
        CPLog(logMessageFormat, packageUrl);
        _isRunningBinaryVersion = NO;
        return packageUrl;
    } else {
        BOOL isRelease = NO;
#ifndef DEBUG
        isRelease = YES;
#endif

        if (isRelease || ![binaryAppVersion isEqualToString:packageAppVersion]) {
            [self clearUpdatesInternal];
        }

        CPLog(logMessageFormat, binaryBundleURL);
        _isRunningBinaryVersion = YES;
        return binaryBundleURL;
    }
}

+ (NSString *)getApplicationSupportDirectory
{
    NSString *applicationSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return applicationSupportDirectory;
}

- (void)overrideAppVersion:(NSString *)appVersion
{
    _codePushConfig.appVersion = appVersion;
}

- (void)setDeploymentKey:(NSString *)deploymentKey
{
    _codePushConfig.deploymentKey = deploymentKey;
}

/*
 * WARNING: This cleans up all downloaded and pending updates.
 */
- (void)clearUpdatesInternal
{
    [_codePushPackage clearUpdates];
    [self removePendingUpdate];
    [self removeFailedUpdates];
}

#pragma mark - Test-only methods

/*
 * This returns a boolean value indicating whether CodePush has
 * been set to run under a test configuration.
 */
+ (BOOL)isUsingTestConfiguration
{
    return testConfigurationFlag;
}

/*
 * This is used to enable an environment in which tests can be run.
 * Specifically, it flips a boolean flag that causes bundles to be
 * saved to a test folder and enables the ability to modify
 * installed bundles on the fly from JavaScript.
 */
+ (void)setUsingTestConfiguration:(BOOL)shouldUseTestConfiguration
{
    testConfigurationFlag = shouldUseTestConfiguration;
}

#pragma mark - Private API methods

@synthesize methodQueue = _methodQueue;
@synthesize pauseCallback = _pauseCallback;
@synthesize paused = _paused;

- (void)setPaused:(BOOL)paused
{
    if (_paused != paused) {
        _paused = paused;
        if (_pauseCallback) {
            _pauseCallback();
        }
    }
}

/*
 * This method is used to clear updates that are installed
 * under a different app version and hence don't apply anymore,
 * during a debug run configuration and when the bridge is
 * running the JS bundle from the dev server.
 */
- (void)clearDebugUpdates
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([super.bridge.bundleURL.scheme hasPrefix:@"http"]) {
            NSError *error;
            NSString *binaryAppVersion = [_codePushConfig appVersion];
            NSDictionary *currentPackageMetadata = [_codePushPackage getCurrentPackage:&error];
            if (currentPackageMetadata) {
                NSString *packageAppVersion = [currentPackageMetadata objectForKey:AppVersionKey];
                if (![binaryAppVersion isEqualToString:packageAppVersion]) {
                    [self clearUpdatesInternal];
                }
            }
        }
    });
}

/*
 * This method is used by the React Native bridge to allow
 * our plugin to expose constants to the JS-side. In our case
 * we're simply exporting enum values so that the JS and Native
 * sides of the plugin can be in sync.
 */
- (NSDictionary *)constantsToExport
{
    // Export the values of the CodePushInstallMode and CodePushUpdateState
    // enums so that the script-side can easily stay in sync
    return @{
             @"codePushInstallModeOnNextRestart":@(CodePushInstallModeOnNextRestart),
             @"codePushInstallModeImmediate": @(CodePushInstallModeImmediate),
             @"codePushInstallModeOnNextResume": @(CodePushInstallModeOnNextResume),
             @"codePushInstallModeOnNextSuspend": @(CodePushInstallModeOnNextSuspend),

             @"codePushUpdateStateRunning": @(CodePushUpdateStateRunning),
             @"codePushUpdateStatePending": @(CodePushUpdateStatePending),
             @"codePushUpdateStateLatest": @(CodePushUpdateStateLatest)
            };
};

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

- (void)dealloc
{
    // Ensure the global resume handler is cleared, so that
    // this object isn't kept alive unnecessarily
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dispatchDownloadProgressEvent {
  // Notify the script-side about the progress
  [self sendEventWithName:DownloadProgressEvent
                     body:@{
                       @"totalBytes" : [NSNumber
                           numberWithLongLong:_latestExpectedContentLength],
                       @"receivedBytes" : [NSNumber
                           numberWithLongLong:_latestReceivedConentLength]
                     }];
}

/*
 * This method ensures that the app was packaged with a JS bundle
 * file, and if not, it throws the appropriate exception.
 */
- (void)ensureBinaryBundleExists
{
    if (![self binaryBundleURL]) {
        NSString *errorMessage;

    #ifdef DEBUG
        #if TARGET_IPHONE_SIMULATOR
            errorMessage = @"React Native doesn't generate your app's JS bundle by default when deploying to the simulator. "
            "If you'd like to test CodePush using the simulator, you can do one of the following depending on your "
            "React Native version and/or preferred workflow:\n\n"

            "1. Update your AppDelegate.m file to load the JS bundle from the packager instead of from CodePush. "
            "You can still test your CodePush update experience using this workflow (Debug builds only).\n\n"

            "2. Force the JS bundle to be generated in simulator builds by adding 'export FORCE_BUNDLING=true' to the script under "
            "\"Build Phases\" > \"Bundle React Native code and images\" (React Native >=0.48 only).\n\n"

            "3. Force the JS bundle to be generated in simulator builds by removing the if block that echoes "
            "\"Skipping bundling for Simulator platform\" in the \"node_modules/react-native/packager/react-native-xcode.sh\" file (React Native <=0.47 only)\n\n"

            "4. Deploy a Release build to the simulator, which unlike Debug builds, will generate the JS bundle (React Native >=0.22.0 only).";
        #else
            errorMessage = [NSString stringWithFormat:@"The specified JS bundle file wasn't found within the app's binary. Is \"%@\" the correct file name?", [bundleResourceName stringByAppendingPathExtension:bundleResourceExtension]];
        #endif
    #else
        errorMessage = @"Something went wrong. Please verify if generated JS bundle is correct. ";
    #endif

        RCTFatal([CodePushErrorUtils errorWithMessage:errorMessage]);
    }
}

- (instancetype)init
{
    self = [super init];

    if (self) {
        [self initializeUpdateAfterRestart];
    }

    return self;
}

/*
 * This method is used when the app is started to either
 * initialize a pending update or rollback a faulty update
 * to the previous version.
 */
- (void)initializeUpdateAfterRestart
{
#ifdef DEBUG
    [self clearDebugUpdates];
#endif
    _paused = YES;
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *pendingUpdateKey = appendKeyWithBundleName(PendingUpdateKey, [self getBundleName]);
    NSDictionary *pendingUpdate = [preferences objectForKey:pendingUpdateKey];

    if (pendingUpdate) {
        _isFirstRunAfterUpdate = YES;
        BOOL updateIsLoading = [pendingUpdate[PendingUpdateIsLoadingKey] boolValue];
        if (updateIsLoading) {
            // Pending update was initialized, but notifyApplicationReady was not called.
            // Therefore, deduce that it is a broken update and rollback.
            CPLog(@"Update did not finish loading the last time, rolling back to a previous version.");
            _needToReportRollback = YES;
            [self rollbackPackage];
        } else {
            // Mark that we tried to initialize the new update, so that if it crashes,
            // we will know that we need to rollback when the app next starts.
            [self savePendingUpdate:pendingUpdate[PendingUpdateHashKey]
                          isLoading:YES];
        }
    }
}

/*
 * This method is used to get information about the latest rollback.
 * This information will be used to decide whether the application
 * should ignore the update or not.
 */
- (NSDictionary *)getLatestRollbackInfo
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *latestRollbackInfoKey = appendKeyWithBundleName(LatestRollbackInfoKey, [self getBundleName]);
    NSDictionary *latestRollbackInfo = [preferences objectForKey:latestRollbackInfoKey];
    return latestRollbackInfo;
}

/*
 * This method is used to save information about the latest rollback.
 * This information will be used to decide whether the application
 * should ignore the update or not.
 */
- (void)setLatestRollbackInfo:(NSString*)packageHash
{
    if (packageHash == nil) {
        return;
    }

    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *latestRollbackInfoKey = appendKeyWithBundleName(LatestRollbackInfoKey, [self getBundleName]);
    NSMutableDictionary *latestRollbackInfo = [preferences objectForKey:latestRollbackInfoKey];
    if (latestRollbackInfo == nil) {
        latestRollbackInfo = [[NSMutableDictionary alloc] init];
    } else {
        latestRollbackInfo = [latestRollbackInfo mutableCopy];
    }

    int initialRollbackCount = [self getRollbackCountForPackage: packageHash fromLatestRollbackInfo: latestRollbackInfo];
    NSNumber *count = [NSNumber numberWithInt: initialRollbackCount + 1];
    NSNumber *currentTimeMillis = [NSNumber numberWithDouble: [[NSDate date] timeIntervalSince1970] * 1000];

    [latestRollbackInfo setValue:count forKey:LatestRollbackCountKey];
    [latestRollbackInfo setValue:currentTimeMillis forKey:LatestRollbackTimeKey];
    [latestRollbackInfo setValue:packageHash forKey:LatestRollbackPackageHashKey];

    [preferences setObject:latestRollbackInfo forKey:LatestRollbackInfoKey];
    [preferences synchronize];
}

/*
 * This method is used to get the count of rollback for the package
 * using the latest rollback information.
 */
- (int)getRollbackCountForPackage:(NSString*) packageHash fromLatestRollbackInfo:(NSMutableDictionary*) latestRollbackInfo
{
    NSString *oldPackageHash = [latestRollbackInfo objectForKey:LatestRollbackPackageHashKey];
    if ([packageHash isEqualToString: oldPackageHash]) {
        NSNumber *oldCount = [latestRollbackInfo objectForKey:LatestRollbackCountKey];
        return [oldCount intValue];
    } else {
        return 0;
    }
}

/*
 * This method checks to see whether a specific package hash
 * has previously failed installation.
 */
- (BOOL)isFailedHash:(NSString*)packageHash
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *failedUpdatesKey = appendKeyWithBundleName(FailedUpdatesKey, [self getBundleName]);
    NSMutableArray *failedUpdates = [preferences objectForKey:failedUpdatesKey];
    if (failedUpdates == nil || packageHash == nil) {
        return NO;
    } else {
        for (NSDictionary *failedPackage in failedUpdates)
        {
            // Type check is needed for backwards compatibility, where we used to just store
            // the failed package hash instead of the metadata. This only impacts "dev"
            // scenarios, since in production we clear out old information whenever a new
            // binary is applied.
            if ([failedPackage isKindOfClass:[NSDictionary class]]) {
                NSString *failedPackageHash = [failedPackage objectForKey:PackageHashKey];
                if ([packageHash isEqualToString:failedPackageHash]) {
                    return YES;
                }
            }
        }

        return NO;
    }
}

/*
 * This method checks to see whether a specific package hash
 * represents a downloaded and installed update, that hasn't
 * been applied yet via an app restart.
 */
- (BOOL)isPendingUpdate:(NSString*)packageHash
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *pendingUpdateKey = appendKeyWithBundleName(PendingUpdateKey, [self getBundleName]);
    NSDictionary *pendingUpdate = [preferences objectForKey:pendingUpdateKey];

    // If there is a pending update whose "state" isn't loading, then we consider it "pending".
    // Additionally, if a specific hash was provided, we ensure it matches that of the pending update.
    BOOL updateIsPending = pendingUpdate &&
                           [pendingUpdate[PendingUpdateIsLoadingKey] boolValue] == NO &&
                           (!packageHash || [pendingUpdate[PendingUpdateHashKey] isEqualToString:packageHash]);

    return updateIsPending;
}

/*
 * This method updates the React Native bridge's bundle URL
 * to point at the latest CodePush update, and then restarts
 * the bridge. This isn't meant to be called directly.
 */
- (void)loadBundle
{
    // This needs to be async dispatched because the bridge is not set on init
    // when the app first starts, therefore rollbacks will not take effect.
    dispatch_async(dispatch_get_main_queue(), ^{
        // If the current bundle URL is using http(s), then assume the dev
        // is debugging and therefore, shouldn't be redirected to a local
        // file (since Chrome wouldn't support it). Otherwise, update
        // the current bundle URL to point at the latest update
        if ([CodePush isUsingTestConfiguration] || ![super.bridge.bundleURL.scheme hasPrefix:@"http"]) {
            [super.bridge setValue:[self bundleURL] forKey:@"bundleURL"];
        }

        [super.bridge reload];
    });
}

/*
 * This method is used when an update has failed installation
 * and the app needs to be rolled back to the previous bundle.
 * This method is automatically called when the rollback timer
 * expires without the app indicating whether the update succeeded,
 * and therefore, it shouldn't be called directly.
 */
- (void)rollbackPackage
{
    NSError *error;
    NSDictionary *failedPackage = [_codePushPackage getCurrentPackage:&error];
    if (!failedPackage) {
        if (error) {
            CPLog(@"Error getting current update metadata during rollback: %@", error);
        } else {
            CPLog(@"Attempted to perform a rollback when there is no current update");
        }
    } else {
        // Write the current package's metadata to the "failed list"
        [self saveFailedUpdate:failedPackage];
    }

    // Rollback to the previous version and de-register the new update
    [_codePushPackage rollbackPackage];
    [self removePendingUpdate];
    [self loadBundle];
}

/*
 * When an update failed to apply, this method can be called
 * to store its hash so that it can be ignored on future
 * attempts to check the server for an update.
 */
- (void)saveFailedUpdate:(NSDictionary *)failedPackage
{
    if ([self isFailedHash:[failedPackage objectForKey:PackageHashKey]]) {
        return;
    }
    
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *failedUpdatesKey = appendKeyWithBundleName(FailedUpdatesKey, [self getBundleName]);
    NSMutableArray *failedUpdates = [preferences objectForKey:failedUpdatesKey];
    if (failedUpdates == nil) {
        failedUpdates = [[NSMutableArray alloc] init];
    } else {
        // The NSUserDefaults sytem always returns immutable
        // objects, regardless if you stored something mutable.
        failedUpdates = [failedUpdates mutableCopy];
    }

    [failedUpdates addObject:failedPackage];
    [preferences setObject:failedUpdates forKey:FailedUpdatesKey];
    [preferences synchronize];
}

/*
 * This method is used to clear away failed updates in the event that
 * a new app store binary is installed.
 */
- (void)removeFailedUpdates
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *failedUpdatesKey = appendKeyWithBundleName(FailedUpdatesKey, [self getBundleName]);
    [preferences removeObjectForKey:failedUpdatesKey];
    [preferences synchronize];
}

/*
 * This method is used to register the fact that a pending
 * update succeeded and therefore can be removed.
 */
- (void)removePendingUpdate
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *pendingUpdateKey = appendKeyWithBundleName(PendingUpdateKey, [self getBundleName]);
    [preferences removeObjectForKey:pendingUpdateKey];
    [preferences synchronize];
}

/*
 * When an update is installed whose mode isn't IMMEDIATE, this method
 * can be called to store the pending update's metadata (e.g. packageHash)
 * so that it can be used when the actual update application occurs at a later point.
 */
- (void)savePendingUpdate:(NSString *)packageHash
                isLoading:(BOOL)isLoading
{
    // Since we're not restarting, we need to store the fact that the update
    // was installed, but hasn't yet become "active".
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSDictionary *pendingUpdate = [[NSDictionary alloc] initWithObjectsAndKeys:
                                   packageHash,PendingUpdateHashKey,
                                   [NSNumber numberWithBool:isLoading],PendingUpdateIsLoadingKey, nil];

    NSString *pendingUpdateKey = appendKeyWithBundleName(PendingUpdateKey, [self getBundleName]);
    [preferences setObject:pendingUpdate forKey:pendingUpdateKey];
    [preferences synchronize];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[DownloadProgressEvent];
}

#pragma mark - Application lifecycle event handlers

// These two handlers will only be registered when there is
// a resume-based update still pending installation.
- (void)applicationWillEnterForeground
{
    if (_appSuspendTimer) {
        [_appSuspendTimer invalidate];
        _appSuspendTimer = nil;
    }
    // Determine how long the app was in the background and ensure
    // that it meets the minimum duration amount of time.
    int durationInBackground = 0;
    if (_lastResignedDate) {
        durationInBackground = [[NSDate date] timeIntervalSinceDate:_lastResignedDate];
    }

    if (durationInBackground >= _minimumBackgroundDuration) {
        [self loadBundle];
    }
}

- (void)applicationWillResignActive
{
    // Save the current time so that when the app is later
    // resumed, we can detect how long it was in the background.
    _lastResignedDate = [NSDate date];

    if (_installMode == CodePushInstallModeOnNextSuspend && [self isPendingUpdate:nil]) {
        _appSuspendTimer = [NSTimer scheduledTimerWithTimeInterval:_minimumBackgroundDuration
                                                         target:self
                                                       selector:@selector(loadBundleOnTick:)
                                                       userInfo:nil
                                                        repeats:NO];
    }
}

-(void)loadBundleOnTick:(NSTimer *)timer {
    [self loadBundle];
}

-(CodePush*) getInstance {
    return _codePushConfig != nil ? self : [CodePush sharedInstance];
}

#pragma mark - JavaScript-exported module methods (Public)

/*
 * This is native-side of the RemotePackage.download method
 */
RCT_EXPORT_METHOD(downloadUpdate:(NSDictionary*)updatePackage
                  notifyProgress:(BOOL)notifyProgress
                        resolver:(RCTPromiseResolveBlock)resolve
                        rejecter:(RCTPromiseRejectBlock)reject)
{
    NSDictionary *mutableUpdatePackage = [updatePackage mutableCopy];
    NSURL *binaryBundleURL = [[self getInstance] binaryBundleURL];
    if (binaryBundleURL != nil) {
        [mutableUpdatePackage setValue:[CodePushUpdateUtils modifiedDateStringOfFileAtURL:binaryBundleURL]
                                forKey:BinaryBundleDateKey];
    }

    if (notifyProgress) {
        // Set up and unpause the frame observer so that it can emit
        // progress events every frame if the progress is updated.
        [self getInstance].didUpdateProgress = NO;
        [self getInstance].paused = NO;
    }

    NSString * publicKey = [[self getInstance].codePushConfig publicKey];

    [[self getInstance].codePushPackage
        downloadPackage:mutableUpdatePackage
        expectedBundleFileName:[[self getInstance].bundleResourceName stringByAppendingPathExtension:[self getInstance].bundleResourceExtension]
        publicKey:publicKey
        codePush:[self getInstance]
        operationQueue:[self getInstance].methodQueue
        // The download is progressing forward
        progressCallback:^(long long expectedContentLength, long long receivedContentLength) {
            // Update the download progress so that the frame observer can notify the JS side
            [self getInstance].latestExpectedContentLength = expectedContentLength;
            [self getInstance].latestReceivedConentLength = receivedContentLength;
            [self getInstance].didUpdateProgress = YES;

            // If the download is completed, stop observing frame
            // updates and synchronously send the last event.
            if (expectedContentLength == receivedContentLength) {
                [self getInstance].didUpdateProgress = NO;
                [self getInstance].paused = YES;
                [self dispatchDownloadProgressEvent];
            }
        }
        // The download completed
        doneCallback:^{
            NSError *err;
            NSDictionary *newPackage = [[self getInstance].codePushPackage getPackage:mutableUpdatePackage[PackageHashKey] error:&err];

            if (err) {
                return reject([NSString stringWithFormat: @"%lu", (long)err.code], err.localizedDescription, err);
            }
            resolve(newPackage);
        }
        // The download failed
        failCallback:^(NSError *err) {
            if ([CodePushErrorUtils isCodePushError:err]) {
                [[self getInstance] saveFailedUpdate:mutableUpdatePackage];
            }

            // Stop observing frame updates if the download fails.
            [self getInstance].didUpdateProgress = NO;
            [self getInstance].paused = YES;
            reject([NSString stringWithFormat: @"%lu", (long)err.code], err.localizedDescription, err);
        }];
}

/*
 * This is the native side of the CodePush.getConfiguration method. It isn't
 * currently exposed via the "react-native-code-push" module, and is used
 * internally only by the CodePush.checkForUpdate method in order to get the
 * app version, as well as the deployment key that was configured in the Info.plist file.
 */
RCT_EXPORT_METHOD(getConfiguration:(RCTPromiseResolveBlock)resolve
                          rejecter:(RCTPromiseRejectBlock)reject)
{
    NSDictionary *configuration = [[self getInstance].codePushConfig configuration];
    NSError *error;
    if ([self getInstance].isRunningBinaryVersion) {
        // isRunningBinaryVersion will not get set to "YES" if running against the packager.
        NSString *binaryHash = [CodePushUpdateUtils getHashForBinaryContents:[[self getInstance] binaryBundleURL] codePush:[self getInstance] error:&error];
        if (error) {
            CPLog(@"Error obtaining hash for binary contents: %@", error);
            resolve(configuration);
            return;
        }

        if (binaryHash == nil) {
            // The hash was not generated either due to a previous unknown error or the fact that
            // the React Native assets were not bundled in the binary (e.g. during dev/simulator)
            // builds.
            resolve(configuration);
            return;
        }

        NSMutableDictionary *mutableConfiguration = [configuration mutableCopy];
        [mutableConfiguration setObject:binaryHash forKey:PackageHashKey];
        resolve(mutableConfiguration);
        return;
    }

    resolve(configuration);
}

/*
 * This method is the native side of the CodePush.getUpdateMetadata method.
 */
RCT_EXPORT_METHOD(getUpdateMetadata:(CodePushUpdateState)updateState
                           resolver:(RCTPromiseResolveBlock)resolve
                           rejecter:(RCTPromiseRejectBlock)reject)
{
    NSError *error;
    NSMutableDictionary *package = [[[self getInstance].codePushPackage getCurrentPackage:&error] mutableCopy];

    if (error) {
        return reject([NSString stringWithFormat: @"%lu", (long)error.code], error.localizedDescription, error);
    } else if (package == nil) {
        // The app hasn't downloaded any CodePush updates yet,
        // so we simply return nil regardless if the user
        // wanted to retrieve the pending or running update.
        return resolve(nil);
    }

    // We have a CodePush update, so let's see if it's currently in a pending state.
    BOOL currentUpdateIsPending = [[self getInstance] isPendingUpdate:[package objectForKey:PackageHashKey]];

    if (updateState == CodePushUpdateStatePending && !currentUpdateIsPending) {
        // The caller wanted a pending update
        // but there isn't currently one.
        resolve(nil);
    } else if (updateState == CodePushUpdateStateRunning && currentUpdateIsPending) {
        // The caller wants the running update, but the current
        // one is pending, so we need to grab the previous.
        resolve([[self getInstance].codePushPackage getPreviousPackage:&error]);
    } else {
        // The current package satisfies the request:
        // 1) Caller wanted a pending, and there is a pending update
        // 2) Caller wanted the running update, and there isn't a pending
        // 3) Caller wants the latest update, regardless if it's pending or not
        if ([self getInstance].isRunningBinaryVersion) {
            // This only matters in Debug builds. Since we do not clear "outdated" updates,
            // we need to indicate to the JS side that somehow we have a current update on
            // disk that is not actually running.
            [package setObject:@(YES) forKey:@"_isDebugOnly"];
        }

        // Enable differentiating pending vs. non-pending updates
        [package setObject:@(currentUpdateIsPending) forKey:PackageIsPendingKey];
        resolve(package);
    }
}

/*
 * This method is the native side of the LocalPackage.install method.
 */
RCT_EXPORT_METHOD(installUpdate:(NSDictionary*)updatePackage
                    installMode:(CodePushInstallMode)installMode
      minimumBackgroundDuration:(int)minimumBackgroundDuration
                       resolver:(RCTPromiseResolveBlock)resolve
                       rejecter:(RCTPromiseRejectBlock)reject)
{
    NSError *error;
    [[self getInstance].codePushPackage installPackage:updatePackage
                                   removePendingUpdate:[[self getInstance] isPendingUpdate:nil]
                                                 error:&error];

    if (error) {
        reject([NSString stringWithFormat: @"%lu", (long)error.code], error.localizedDescription, error);
    } else {
        [[self getInstance] savePendingUpdate:updatePackage[PackageHashKey]
                                    isLoading:NO];

        [self getInstance].installMode = installMode;
        if ([self getInstance].installMode == CodePushInstallModeOnNextResume || [self getInstance].installMode == CodePushInstallModeOnNextSuspend) {
            [self getInstance].minimumBackgroundDuration = minimumBackgroundDuration;

            if (![self getInstance].hasResumeListener) {
                // Ensure we do not add the listener twice.
                // Register for app resume notifications so that we
                // can check for pending updates which support "restart on resume"
                [[NSNotificationCenter defaultCenter] addObserver:[self getInstance]
                                                         selector:@selector(applicationWillEnterForeground)
                                                             name:UIApplicationWillEnterForegroundNotification
                                                           object:RCTSharedApplication()];

                [[NSNotificationCenter defaultCenter] addObserver:[self getInstance]
                                                         selector:@selector(applicationWillResignActive)
                                                             name:UIApplicationWillResignActiveNotification
                                                           object:RCTSharedApplication()];

                [self getInstance].hasResumeListener = YES;
            }
        }

        // Signal to JS that the update has been applied.
        resolve(nil);
    }
}

/*
 * This method isn't publicly exposed via the "react-native-code-push"
 * module, and is only used internally to populate the RemotePackage.failedInstall property.
 */
RCT_EXPORT_METHOD(isFailedUpdate:(NSString *)packageHash
                         resolve:(RCTPromiseResolveBlock)resolve
                          reject:(RCTPromiseRejectBlock)reject)
{
    BOOL isFailedHash = [[self getInstance] isFailedHash:packageHash];
    resolve(@(isFailedHash));
}

RCT_EXPORT_METHOD(setLatestRollbackInfo:(NSString *)packageHash
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    [[self getInstance] setLatestRollbackInfo:packageHash];
}


RCT_EXPORT_METHOD(getLatestRollbackInfo:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSDictionary *latestRollbackInfo = [[self getInstance] getLatestRollbackInfo];
    resolve(latestRollbackInfo);
}

/*
 * This method isn't publicly exposed via the "react-native-code-push"
 * module, and is only used internally to populate the LocalPackage.isFirstRun property.
 */
RCT_EXPORT_METHOD(isFirstRun:(NSString *)packageHash
                     resolve:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
{
    NSError *error;
    BOOL isFirstRun = [self getInstance].isFirstRunAfterUpdate
                        && nil != packageHash
                        && [packageHash length] > 0
                        && [packageHash isEqualToString:[[self getInstance].codePushPackage                       getCurrentPackageHash:&error]];

    resolve(@(isFirstRun));
}

/*
 * This method is the native side of the CodePush.notifyApplicationReady() method.
 */
RCT_EXPORT_METHOD(notifyApplicationReady:(RCTPromiseResolveBlock)resolve
                                rejecter:(RCTPromiseRejectBlock)reject)
{
    [[self getInstance] removePendingUpdate];
    resolve(nil);
}

/*
 * This method is the native side of the CodePush.restartApp() method.
 */
RCT_EXPORT_METHOD(restartApp:(BOOL)onlyIfUpdateIsPending
                     resolve:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
{
    // If this is an unconditional restart request, or there
    // is current pending update, then trigger viewDidLoad on top most VC
    if (!onlyIfUpdateIsPending || [[self getInstance] isPendingUpdate:nil]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
           // do work here
           UIViewController *vc = [[self getInstance] topViewController];
           [vc viewDidLoad];
           [[NSNotificationCenter defaultCenter]
             postNotificationName:@"RCTJavaScriptDidLoadNotification"
             object:[self getInstance]];
           resolve(@(YES));
        });

        return;
    }

    resolve(@(NO));
}

- (UIViewController *)topViewController{
    return [self topViewController:[UIApplication sharedApplication].keyWindow.rootViewController];
}

- (UIViewController *)topViewController:(UIViewController *)rootViewController
{
    if ([rootViewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)rootViewController;
        return [self topViewController:[navigationController.viewControllers lastObject]];
    }
    if ([rootViewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabController = (UITabBarController *)rootViewController;
        return [self topViewController:tabController.selectedViewController];
    }
    if (rootViewController.presentedViewController) {
        return [self topViewController:rootViewController];
    }
    return rootViewController;
}
/*
 * This method clears CodePush's downloaded updates.
 * It is needed to switch to a different deployment if the current deployment is more recent.
 * Note: we don’t recommend to use this method in scenarios other than that (CodePush will call this method
 * automatically when needed in other cases) as it could lead to unpredictable behavior.
 */
RCT_EXPORT_METHOD(clearUpdates) {
    CPLog(@"Clearing updates.");
    [[self getInstance] clearUpdatesInternal];
}

#pragma mark - JavaScript-exported module methods (Private)

/*
 * This method is the native side of the CodePush.downloadAndReplaceCurrentBundle()
 * method, which replaces the current bundle with the one downloaded from
 * removeBundleUrl. It is only to be used during tests and no-ops if the test
 * configuration flag is not set.
 */
RCT_EXPORT_METHOD(downloadAndReplaceCurrentBundle:(NSString *)remoteBundleUrl)
{
    if ([CodePush isUsingTestConfiguration]) {
        [[self getInstance].codePushPackage downloadAndReplaceCurrentBundle:remoteBundleUrl];
    }
}

/*
 * This method is checks if a new status update exists (new version was installed,
 * or an update failed) and return its details (version label, status).
 */
RCT_EXPORT_METHOD(getNewStatusReport:(RCTPromiseResolveBlock)resolve
                            rejecter:(RCTPromiseRejectBlock)reject)
{
    if ([self getInstance].needToReportRollback) {
        [self getInstance].needToReportRollback = NO;
        NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
        NSString *failedUpdatesKey = appendKeyWithBundleName(FailedUpdatesKey, [[self getInstance] getBundleName]);
        NSMutableArray *failedUpdates = [preferences objectForKey:failedUpdatesKey];
        if (failedUpdates) {
            NSDictionary *lastFailedPackage = [failedUpdates lastObject];
            if (lastFailedPackage) {
                resolve([[self getInstance].codePushTelemetryManager getRollbackReport:lastFailedPackage]);
                return;
            }
        }
    } else if ([self getInstance].isFirstRunAfterUpdate) {
        NSError *error;
        NSDictionary *currentPackage = [[self getInstance].codePushPackage getCurrentPackage:&error];
        if (!error && currentPackage) {
            resolve([[self getInstance].codePushTelemetryManager getUpdateReport:currentPackage]);
            return;
        }
    } else if ([self getInstance].isRunningBinaryVersion) {
        NSString *appVersion = [[CodePushConfig current] appVersion];
        resolve([[self getInstance].codePushTelemetryManager getBinaryUpdateReport:appVersion]);
        return;
    } else {
        NSDictionary *retryStatusReport = [[self getInstance].codePushTelemetryManager getRetryStatusReport];
        if (retryStatusReport) {
            resolve(retryStatusReport);
            return;
        }
    }

    resolve(nil);
}

RCT_EXPORT_METHOD(recordStatusReported:(NSDictionary *)statusReport)
{
    [[self getInstance].codePushTelemetryManager recordStatusReported:statusReport];
}

RCT_EXPORT_METHOD(saveStatusReportForRetry:(NSDictionary *)statusReport)
{
    [[self getInstance].codePushTelemetryManager saveStatusReportForRetry:statusReport];
}

#pragma mark - RCTFrameUpdateObserver Methods

- (void)didUpdateFrame:(RCTFrameUpdate *)update
{
    if (!_didUpdateProgress) {
        return;
    }

    [self dispatchDownloadProgressEvent];
    _didUpdateProgress = NO;
}

@end
