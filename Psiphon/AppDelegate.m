/*
 * Copyright (c) 2015, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import <PsiphonTunnel/Reachability.h>
#import <ReactiveObjC/RACTuple.h>
#import <NetworkExtension/NetworkExtension.h>
#import <ReactiveObjC/RACScheduler.h>
#import "AppDelegate.h"
#import "AdManager.h"
#import "EmbeddedServerEntries.h"
#import "IAPViewController.h"
#import "Logging.h"
#import "MPInterstitialAdController.h"
#import "Notifier.h"
#import "PsiphonClientCommonLibraryHelpers.h"
#import "PsiphonConfigFiles.h"
#import "PsiphonDataSharedDB.h"
#import "RootContainerController.h"
#import "SharedConstants.h"
#import "UIAlertController+Delegate.h"
#import "VPNManager.h"
#import "AdManager.h"
#import "Logging.h"
#import "IAPStoreHelper.h"
#import "NEBridge.h"
#import "DispatchUtils.h"
#import "PsiFeedbackLogger.h"
#import "RACSignal.h"
#import "RACSignal+Operations2.h"
#import "NSError+Convenience.h"
#import "RACCompoundDisposable.h"
#import "RACSignal+Operations.h"
#import "RACReplaySubject.h"
#import "Asserts.h"

// Number of seconds to wait for tunnel status to become "Connected", after the landing page notification
// is received from the extension.
#define kLandingPageTimeoutSecs 1.0

PsiFeedbackLogType const LandingPageLogType = @"LandingPage";

@interface AppDelegate ()

// Public properties

// subscriptionStatus should only be sent events to from the main thread.
@property (nonatomic, readwrite) RACReplaySubject<NSNumber *> *subscriptionStatus;

// Private properties
@property (atomic) BOOL shownLandingPageForCurrentSession;
@property (nonatomic) RACCompoundDisposable *compoundDisposable;

@property (nonatomic) VPNManager *vpnManager;
@property (nonatomic) PsiphonDataSharedDB *sharedDB;
@property (nonatomic) NSTimer *subscriptionCheckTimer;

@end

@implementation AppDelegate {
    AdManager *adManager;
    Notifier *notifier;

    RootContainerController *rootContainerController;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        adManager = [AdManager sharedInstance];
        notifier = [[Notifier alloc] initWithAppGroupIdentifier:APP_GROUP_IDENTIFIER];

        _subscriptionStatus = [RACReplaySubject replaySubjectWithCapacity:1];
        [_subscriptionStatus sendNext:@(UserSubscriptionUnknown)];

        _vpnManager = [VPNManager sharedInstance];
        _sharedDB = [[PsiphonDataSharedDB alloc] initForAppGroupIdentifier:APP_GROUP_IDENTIFIER];
        _shownLandingPageForCurrentSession = FALSE;
        _compoundDisposable = [RACCompoundDisposable compoundDisposable];
    }
    return self;
}

- (void)dealloc {
    [self.compoundDisposable dispose];
}

+ (AppDelegate *)sharedAppDelegate {
    return (AppDelegate *)[UIApplication sharedApplication].delegate;
}

+ (BOOL)isFirstRunOfAppVersion {
    static BOOL firstRunOfVersion;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        NSString *appVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
        NSString *lastLaunchAppVersion = [userDefaults stringForKey:@"LastCFBundleVersion"];
        if ([appVersion isEqualToString:lastLaunchAppVersion]) {
            firstRunOfVersion = FALSE;
        } else {
            firstRunOfVersion = TRUE;
            [userDefaults setObject:appVersion forKey:@"LastCFBundleVersion"];
        }
    });
    return firstRunOfVersion;
}

+ (BOOL)isRunningUITest {
#if DEBUG
    static BOOL runningUITest;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"FASTLANE_SNAPSHOT"]) {
            NSDictionary *environmentDictionary = [[NSProcessInfo processInfo] environment];
            if (environmentDictionary[@"PsiphonUITestEnvironment"] != nil) {
                runningUITest = TRUE;
            }
        }

    });
    return runningUITest;
#else
    return FALSE;
#endif
}

# pragma mark - Lifecycle methods

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self initializeDefaults];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onAdsLoaded)
                                                 name:AdManagerAdsDidLoadNotification
                                               object:adManager];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onUpdatedSubscriptionDictionary)
                                                 name:IAPHelperUpdatedSubscriptionDictionaryNotification
                                               object:nil];

    [[IAPStoreHelper sharedInstance] startProductsRequest];

    if ([AppDelegate isFirstRunOfAppVersion]) {
        [self updateAvailableEgressRegionsOnFirstRunOfAppVersion];
    }

    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    LOG_DEBUG();

    __weak AppDelegate *weakSelf = self;

    // Override point for customization after application launch.
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    rootContainerController = [[RootContainerController alloc] init];
    self.window.rootViewController = rootContainerController;

    // UIKit always waits for application:didFinishLaunchingWithOptions:
    // to return before making the window visible on the screen.
    [self.window makeKeyAndVisible];

    [self loadAdsIfNeeded];

    // Listen for VPN status changes from VPNManager.
    __block RACDisposable *disposable = [self.vpnManager.lastTunnelStatus
      subscribeNext:^(NSNumber *statusObject) {
          VPNStatus s = (VPNStatus) [statusObject integerValue];

          if (s == VPNStatusDisconnected || s == VPNStatusRestarting ) {
              // Resets the homepage flag if the VPN has disconnected or is restarting.
              weakSelf.shownLandingPageForCurrentSession = FALSE;
          }

      } error:^(NSError *error) {
          [weakSelf.compoundDisposable removeDisposable:disposable];
      } completed:^{
          [weakSelf.compoundDisposable removeDisposable:disposable];
      }];

    [self.compoundDisposable addDisposable:disposable];

    // Listen for the network extension messages.
    [self listenForNEMessages];

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    LOG_DEBUG();

    __weak AppDelegate *weakSelf = self;

    // Starts subscription expiry timer if there is an active subscription.
    [self subscriptionExpiryTimer];

    // Before submitting any other work to the VPNManager, update its status.
    [self.vpnManager checkOrFixVPNStatus];

    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self.sharedDB updateAppForegroundState:YES];

    // If the extension has been waiting for the app to come into foreground,
    // send the VPNManager startVPN message again.
    if (![adManager untunneledInterstitialIsShowing]) {

        __block RACDisposable *disposable = [[self.vpnManager isPsiphonTunnelConnected]
          subscribeNext:^(NSNumber *_Nullable connected) {
              if ([connected boolValue]) {
                  [weakSelf.vpnManager startVPN];
              }
          } error:^(NSError *error) {
              [weakSelf.compoundDisposable removeDisposable:disposable];
          } completed:^{
              [weakSelf.compoundDisposable removeDisposable:disposable];
          }];

        [self.compoundDisposable addDisposable:disposable];

    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    LOG_DEBUG();
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.

    // Cancel subscription expiry timer if active.
    [self.subscriptionCheckTimer invalidate];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    LOG_DEBUG();
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.

    [[UIApplication sharedApplication] ignoreSnapshotOnNextApplicationLaunch];
    [notifier post:NOTIFIER_APP_DID_ENTER_BACKGROUND];
    [self.sharedDB updateAppForegroundState:NO];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    LOG_DEBUG();
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.

    [self loadAdsIfNeeded];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    LOG_DEBUG();
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

#pragma mark -

- (void)initializeDefaults {
    [PsiphonClientCommonLibraryHelpers initializeDefaultsForPlistsFromRoot:@"Root.inApp"];
}

- (void)reloadMainViewController {
    LOG_DEBUG();
    [rootContainerController reloadMainViewController];
    rootContainerController.mainViewController.openSettingImmediatelyOnViewDidAppear = TRUE;
}

#pragma mark - Ads

- (void)loadAdsIfNeeded {

    VPNStatus s = (VPNStatus) [[[self.vpnManager lastTunnelStatus] first] integerValue];

    if ([adManager shouldShowUntunneledAds] &&
        ![adManager untunneledInterstitialIsReady] &&
        ![adManager untunneledInterstitialHasShown] &&
        (s == VPNStatusInvalid || s == VPNStatusDisconnected)
      ){

        [rootContainerController showLaunchScreen];

        dispatch_async(dispatch_get_main_queue(), ^{
                [adManager initializeAds];
        });

    } else {
        // Removes launch screen if already showing.
        [rootContainerController removeLaunchScreen];
    }
}

// Returns the ViewController responsible for presenting ads.
- (UIViewController *)getAdsPresentingViewController {
    return rootContainerController.mainViewController;
}

- (void)onAdsLoaded {
    LOG_DEBUG();
    [rootContainerController removeLaunchScreen];
}

- (void)launchScreenFinished {
    LOG_DEBUG();
    [rootContainerController removeLaunchScreen];
}

#pragma mark - Embedded Server Entries

/*!
 * @brief Updates available egress regions from embedded server entries.
 *
 * This function should only be called once per app version on first launch.
 */
- (void)updateAvailableEgressRegionsOnFirstRunOfAppVersion {
    NSString *embeddedServerEntriesPath = [PsiphonConfigFiles embeddedServerEntriesPath];
    NSArray *embeddedEgressRegions = [EmbeddedServerEntries egressRegionsFromFile:embeddedServerEntriesPath];

    LOG_DEBUG("Available embedded egress regions: %@.", embeddedEgressRegions);

    if ([embeddedEgressRegions count] > 0) {
        [self.sharedDB insertNewEmbeddedEgressRegions:embeddedEgressRegions];
    } else {
        [PsiFeedbackLogger error:@"Error no egress regions found in %@.", embeddedServerEntriesPath];
    }
}

#pragma mark - Network Extension

- (void)listenForNEMessages {

    __weak AppDelegate *weakSelf = self;

    [notifier listenForNotification:NOTIFIER_NEW_HOMEPAGES listener:^(NSString *key){
        LOG_DEBUG(@"Received notification NE.newHomepages");

        // Ignore the notification from the extension, since a landing page has
        // already been shown for the current session.
        if (weakSelf.shownLandingPageForCurrentSession) {
            return;
        }

        // Eagerly set the value to TRUE.
        weakSelf.shownLandingPageForCurrentSession = TRUE;
        
        dispatch_async_global(^{

            // If a landing page is not already shown for the current session, randomly choose
            // a landing page from the list supplied by Psiphon tunnel.

            NSArray<Homepage *> *homepages = [weakSelf.sharedDB getHomepages];

            if (!homepages || [homepages count] == 0) {
                weakSelf.shownLandingPageForCurrentSession = FALSE;
                return;
            }

            NSUInteger randIndex = arc4random() % [homepages count];
            Homepage *homepage = homepages[randIndex];

            // Only opens landing page if the VPN is active (or waits up to a maximum of kLandingPageTimeoutSecs
            // for the tunnel status to become "Connected" before opening the landing page).
            // Landing page should not be opened outside of the tunnel.

            __block RACDisposable *disposable = [[[[[[[weakSelf.vpnManager isExtensionZombie]
              combineLatestWith:weakSelf.vpnManager.lastTunnelStatus]
              filter:^BOOL(RACTwoTuple<NSNumber *, NSNumber *> *tuple) {

                  // We're only interested in the Connected status.
                  VPNStatus s = (VPNStatus) [tuple.second integerValue];
                  return (s == VPNStatusConnected);
              }]
              take:1]  // Take 1 to terminate the infinite signal.
              timeout:kLandingPageTimeoutSecs onScheduler:RACScheduler.mainThreadScheduler]
              deliverOnMainThread]
              subscribeNext:^(RACTwoTuple<NSNumber *, NSNumber *> *x) {
                  BOOL isZombie = [x.first boolValue];

                  if (isZombie) {
                      weakSelf.shownLandingPageForCurrentSession = FALSE;
                      return;
                  }

                  NEVPNStatus s = weakSelf.vpnManager.tunnelProviderStatus;
                  if (NEVPNStatusConnected == s) {

                      [PsiFeedbackLogger infoWithType:LandingPageLogType message:@"open landing page"];

                      // Not officially documented by Apple, however a runtime warning is generated sometimes
                      // stating that [UIApplication openURL:options:completionHandler:] must be used from
                      // the main thread only.
                      [[UIApplication sharedApplication] openURL:homepage.url
                                                         options:@{}
                                               completionHandler:^(BOOL success) {
                                                   weakSelf.shownLandingPageForCurrentSession = success;
                                               }];
                  } else {

                      [PsiFeedbackLogger warnWithType:LandingPageLogType
                                              message:@"fail open with connection status %@", [VPNManager statusTextSystem:s]];
                      weakSelf.shownLandingPageForCurrentSession = FALSE;
                  }

              } error:^(NSError *error) {
                  [PsiFeedbackLogger warnWithType:LandingPageLogType message:@"timeout expired" object:error];
                  [weakSelf.compoundDisposable removeDisposable:disposable];
              } completed:^{
                  [weakSelf.compoundDisposable removeDisposable:disposable];
              }];

            [weakSelf.compoundDisposable addDisposable:disposable];

        });
    }];

    [notifier listenForNotification:NOTIFIER_TUNNEL_CONNECTED listener:^(NSString *key){
        LOG_DEBUG(@"Received notification NE.tunnelConnected");

        // If we haven't had a chance to load an Ad, and the
        // tunnel is already connected, give up on the Ad and
        // start the VPN. Otherwise the startVPN message will be
        // sent after the Ad has disappeared.
        if (![adManager untunneledInterstitialIsShowing]) {
            [weakSelf.vpnManager startVPN];
        }
    }];

    [notifier listenForNotification:NOTIFIER_ON_AVAILABLE_EGRESS_REGIONS listener:^(NSString *key){
        LOG_DEBUG(@"Received notification NE.onAvailableEgressRegions");
        // Update available regions
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSArray<NSString *> *regions = [weakSelf.sharedDB emittedEgressRegions];
            [[RegionAdapter sharedInstance] onAvailableEgressRegions:regions];
        });
    }];
}

#pragma mark - Subscription

- (void)subscriptionExpiryTimer {

    __weak AppDelegate *weakSelf = self;

    dispatch_async_global(^{
        NSDate *expiryDate;
        BOOL activeSubscription = [IAPStoreHelper hasActiveSubscriptionForDate:[NSDate date] getExpiryDate:&expiryDate];

        dispatch_async_main(^{
            if (activeSubscription) {

                // Also update the subscription status subject.
                [weakSelf.subscriptionStatus sendNext:@(UserSubscriptionActive)];

                NSTimeInterval interval = [expiryDate timeIntervalSinceNow];
                
                if (interval > 0) {
                    // Checks if another timer is already running.
                    if (![weakSelf.subscriptionCheckTimer isValid]) {
                        weakSelf.subscriptionCheckTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                                                 repeats:NO
                                                                                   block:^(NSTimer *timer) {
                            [weakSelf subscriptionExpiryTimer];
                        }];
                    }
                }
            } else {
                // Instead of subscribing to the notification in this class, calls the handler directly.
                [weakSelf onSubscriptionExpired];
            }
        });
    });
}

- (void)onSubscriptionExpired {

    __weak AppDelegate *weakSelf = self;

    [self.subscriptionStatus sendNext:@(UserSubscriptionInactive)];

    // Disables Connect On Demand setting of the VPN Configuration.
    __block RACDisposable *disposable = [[self.vpnManager setConnectOnDemandEnabled:FALSE]
      subscribeError:^(NSError *error) {
          [weakSelf.compoundDisposable removeDisposable:disposable];
      } completed:^{
          [weakSelf.compoundDisposable removeDisposable:disposable];
      }];

    [self.compoundDisposable addDisposable:disposable];
}

- (void)onSubscriptionActivated {

    __weak AppDelegate *weakSelf = self;

    [self.subscriptionStatus sendNext:@(UserSubscriptionActive)];

    [self subscriptionExpiryTimer];

    // Asks the extension to perform a subscription check if it is running currently.
    __block RACDisposable *vpnActiveDisposable = [[self.vpnManager isVPNActive]
      subscribeNext:^(RACTwoTuple<NSNumber *, NSNumber *> *value) {
        BOOL isActive = [value.first boolValue];

        if (isActive) {
            [notifier post:NOTIFIER_FORCE_SUBSCRIPTION_CHECK];
        }

    } error:^(NSError *error) {
        [weakSelf.compoundDisposable removeDisposable:vpnActiveDisposable];
    } completed:^{
        [weakSelf.compoundDisposable removeDisposable:vpnActiveDisposable];
    }];

    [self.compoundDisposable addDisposable:vpnActiveDisposable];

    // Checks if user previously preferred to have Connect On Demand enabled,
    // Re-enable it upon subscription since it may have been disabled if the previous subscription expired.
    // Disables Connect On Demand setting of the VPN Configuration.
    BOOL userPreferredOnDemandSetting = [[NSUserDefaults standardUserDefaults]
      boolForKey:SettingsConnectOnDemandBoolKey];

    __block RACDisposable *onDemandDisposable = [[self.vpnManager setConnectOnDemandEnabled:userPreferredOnDemandSetting]
      subscribeError:^(NSError *error) {
          [weakSelf.compoundDisposable removeDisposable:onDemandDisposable];
    } completed:^{
          [weakSelf.compoundDisposable removeDisposable:onDemandDisposable];
    }];

    [self.compoundDisposable addDisposable:onDemandDisposable];

}

// Called on `IAPHelperUpdatedSubscriptionDictionaryNotification` notification.
- (void)onUpdatedSubscriptionDictionary {

    if (![adManager shouldShowUntunneledAds]) {
        // if user subscription state has changed to valid
        // try to deinit ads if currently not showing and hide adLabel
        [adManager initializeAds];
    }

    __weak AppDelegate *weakSelf = self;

    dispatch_async_global(^{

        BOOL isSubscribed = [IAPStoreHelper hasActiveSubscriptionForNow];

        dispatch_async_main(^{

            if (isSubscribed) {
                [weakSelf onSubscriptionActivated];

            }
        });
    });
}

#pragma mark -

+ (UIViewController *)getTopMostViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while(topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}

@end
