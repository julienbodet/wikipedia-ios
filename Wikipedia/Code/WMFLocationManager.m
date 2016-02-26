
#import "WMFLocationManager.h"
#import "WMFLocationSearchFetcher.h"

static DDLogLevel WMFLocationManagerLogLevel = DDLogLevelInfo;

#undef LOG_LEVEL_DEF
#define LOG_LEVEL_DEF WMFLocationManagerLogLevel

NS_ASSUME_NONNULL_BEGIN

@interface WMFLocationManager ()<CLLocationManagerDelegate>

@property (nonatomic, strong, readwrite) CLLocationManager* locationManager;
@property (nonatomic, strong, nullable) id orientationNotificationToken;

/**
 *  @name Location Manager State
 *
 *  We need to keep track of these properties to ensure that the UI isn't emptied if the location manager is restarted,
 *  which will temporarily set its @c location and @c heading properties to @c nil.
 */

/**
 *  The last-known location reported by the @c locationManager.
 */
@property (nonatomic, strong, readwrite, nullable) CLLocation* lastLocation;

/**
 *  The last-known heading reported by the @c locationManager.
 */
@property (nonatomic, strong, readwrite, nullable) CLHeading* lastHeading;

@property (nonatomic, assign, readwrite, getter=isUpdating) BOOL updating;

@end

@implementation WMFLocationManager

- (void)dealloc {
    self.locationManager.delegate = nil;
    [self stopMonitoringLocation];
}

#pragma mark - Accessors

- (CLHeading*)heading {
    return self.lastHeading;
}

- (CLLocation*)location {
    return self.lastLocation;
}

- (CLLocationManager*)locationManager {
    if (!_locationManager) {
        _locationManager                 = [[CLLocationManager alloc] init];
        _locationManager.delegate        = self;
        _locationManager.desiredAccuracy = kCLLocationAccuracyKilometer;
        _locationManager.activityType    = CLActivityTypeFitness;
        /*
           Update location every 1 meter. This is separate from how often we update the titles that are near a given
           location.
         */
        _locationManager.distanceFilter = 1;
    }
    return _locationManager;
}

- (NSString*)description {
    NSString* delegateDesc = [self.delegate description] ? : @"nil";
    return [NSString stringWithFormat:@"<%@ manager: %@ delegate: %@ is updating: %d>",
            [super description], _locationManager, delegateDesc, self.isUpdating];
}

#pragma mark - Permissions

+ (BOOL)isAuthorized {
    return [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse;
}

+ (BOOL)isDeniedOrDisabled {
    return [CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied || [CLLocationManager authorizationStatus] == kCLAuthorizationStatusRestricted;
}

- (BOOL)requestAuthorizationIfNeeded {
    CLAuthorizationStatus status = [CLLocationManager authorizationStatus];
    if (status == kCLAuthorizationStatusNotDetermined) {
        NSParameterAssert([CLLocationManager locationServicesEnabled]);
        DDLogInfo(@"%@ is requesting authorization to access location when in use.", self);
        [self.locationManager requestWhenInUseAuthorization];
        return YES;
    }
    DDLogVerbose(@"%@ is skipping authorization request because status is %d.", self, status);
    return NO;
}

#pragma mark - Location Monitoring

- (void)restartLocationMonitoring {
    [self stopMonitoringLocation];
    [self startMonitoringLocation];
}

- (void)startMonitoringLocation {
    if ([self requestAuthorizationIfNeeded] || [WMFLocationManager isDeniedOrDisabled]) {
        return;
    }

    NSParameterAssert([WMFLocationManager isAuthorized]);

    DDLogVerbose(@"%@ will start location & heading updates.", self);

    self.updating = YES;
    [self startLocationUpdates];
    [self startHeadingUpdates];
}

- (void)stopMonitoringLocation {
    DDLogVerbose(@"%@ will stop location & heading updates.", self);
    self.updating = NO;
    [self stopLocationUpdates];
    [self stopHeadingUpdates];
}

#pragma mark - Location Updates

- (void)startLocationUpdates {
    [self.locationManager startUpdatingLocation];
}

- (void)startHeadingUpdates {
    if (![[UIDevice currentDevice] isGeneratingDeviceOrientationNotifications]) {
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    }
    @weakify(self);
    self.orientationNotificationToken =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification* _) {
        @strongify(self);
        [self updateHeadingOrientation];
    }];
    [self updateHeadingOrientation];
    [self.locationManager startUpdatingHeading];
}

- (void)updateHeadingOrientation {
    switch ([[UIDevice currentDevice] orientation]) {
        case UIDeviceOrientationFaceDown:
            self.locationManager.headingOrientation = CLDeviceOrientationFaceDown;
            break;
        case UIDeviceOrientationLandscapeLeft:
            self.locationManager.headingOrientation = CLDeviceOrientationLandscapeLeft;
            break;
        case UIDeviceOrientationLandscapeRight:
            self.locationManager.headingOrientation = CLDeviceOrientationLandscapeRight;
            break;
        case UIDeviceOrientationFaceUp:
            self.locationManager.headingOrientation = CLDeviceOrientationFaceUp;
            break;
        case UIDeviceOrientationPortrait:
            self.locationManager.headingOrientation = CLDeviceOrientationPortrait;
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            self.locationManager.headingOrientation = CLDeviceOrientationPortraitUpsideDown;
            break;
        case UIDeviceOrientationUnknown:
        default:
            self.locationManager.headingOrientation = CLDeviceOrientationUnknown;
            break;
    }
    // Force location manager to re-emit the current heading which will take into account the current device orientation
    [self.locationManager stopUpdatingHeading];
    [self.locationManager startUpdatingHeading];
}

- (void)stopLocationUpdates {
    [self.locationManager stopUpdatingLocation];
}

- (void)stopHeadingUpdates {
    [[NSNotificationCenter defaultCenter] removeObserver:self.orientationNotificationToken];
    self.orientationNotificationToken = nil;
    [self.locationManager stopUpdatingHeading];
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager*)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    switch (status) {
        case kCLAuthorizationStatusNotDetermined:
        case kCLAuthorizationStatusRestricted: {
            DDLogVerbose(@"Ignoring not determined status call, should have already requested authorization.");
            break;
        }

        case kCLAuthorizationStatusDenied: {
            if ([self.delegate respondsToSelector:@selector(nearbyController:didChangeEnabledState:)]) {
                DDLogInfo(@"Informing delegate about denied access to user's location.");
                [self.delegate nearbyController:self didChangeEnabledState:NO];
            }
            break;
        }

        case kCLAuthorizationStatusAuthorizedWhenInUse:
        case kCLAuthorizationStatusAuthorizedAlways: {
            DDLogInfo(@"%@ was granted access to location when in use, attempting to monitor location.", self);
            if ([self.delegate respondsToSelector:@selector(nearbyController:didChangeEnabledState:)]) {
                [self.delegate nearbyController:self didChangeEnabledState:YES];
            }
            [self startMonitoringLocation];
            break;
        }
    }
}

- (void)locationManager:(CLLocationManager*)manager didUpdateLocations:(NSArray*)locations {
    // ignore nil values to keep last known heading on the screen
    if (!self.isUpdating || !manager.location) {
        return;
    }
    self.lastLocation = manager.location;
    DDLogVerbose(@"%@ updated location: %@", self, self.lastLocation);
    [self.delegate nearbyController:self didUpdateLocation:self.lastLocation];
}

- (void)locationManager:(CLLocationManager*)manager didUpdateHeading:(CLHeading*)newHeading {
    // ignore nil or innaccurate values values to keep last known heading on the screen
    if (!self.isUpdating || !newHeading || newHeading.headingAccuracy <= 0) {
        return;
    }
    self.lastHeading = newHeading;
    DDLogVerbose(@"%@ updated heading to %@", self, self.lastHeading);
    [self.delegate nearbyController:self didUpdateHeading:self.lastHeading];
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error {
    if (!self.isUpdating) {
        DDLogVerbose(@"Suppressing error received after call to stop monitoring location: %@", error);
        return;
    }
    #if TARGET_IPHONE_SIMULATOR
    else if (error.domain == kCLErrorDomain && error.code == kCLErrorLocationUnknown) {
        DDLogVerbose(@"Suppressing unknown location error.");
        return;
    }
    #endif
    DDLogError(@"%@ encountered error: %@", self, error);
    [self.delegate nearbyController:self didReceiveError:error];
}

#pragma mark - Geocoding

- (AnyPromise*)reverseGeocodeLocation:(CLLocation*)location {
    return [AnyPromise promiseWithResolverBlock:^(PMKResolver _Nonnull resolve) {
        [[[CLGeocoder alloc] init] reverseGeocodeLocation:location completionHandler:^(NSArray <CLPlacemark*>* _Nullable placemarks, NSError* _Nullable error) {
            if (error) {
                resolve(error);
            } else {
                resolve(placemarks.firstObject);
            }
        }];
    }];
}

@end

NS_ASSUME_NONNULL_END
