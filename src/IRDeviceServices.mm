/* GPL-2.0-only */

#import "IRDeviceServices.h"

#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <unistd.h>

static NSString *const IRDeviceServicesErrorDomain = @"com.82flex.trollvnc.device-services";

@interface IRDeviceServices ()
- (BOOL)prepareWifi;
@end

@implementation IRDeviceServices {
    void *mWifiHandle;
    void *mWifiManager;
    void *mWifiDevice;
    void *(*mWifiCreate)(CFAllocatorRef, int);
    CFArrayRef (*mWifiCopyDevices)(void *);
    int (*mWifiGetPower)(void *);
    void (*mWifiSetPower)(void *, int);
    void (*mWifiSetProperty)(void *, CFStringRef, CFPropertyListRef);
    NSString *mWifiError;
}

+ (instancetype)sharedServices {
    static IRDeviceServices *services;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ services = [[self alloc] init]; });
    return services;
}

- (instancetype)init {
    self = [super init];
    return self;
}

- (BOOL)prepareWifi {
    if (mWifiDevice) {
        mWifiError = nil;
        return YES;
    }
    if (!mWifiHandle)
    mWifiHandle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW | RTLD_LOCAL);
    if (!mWifiHandle) {
        mWifiError = @"mobilewifi-framework-unavailable";
        return NO;
    }
    if (!mWifiCreate)
        mWifiCreate = (void *(*)(CFAllocatorRef, int))dlsym(mWifiHandle, "WiFiManagerClientCreate");
    if (!mWifiCopyDevices)
        mWifiCopyDevices = (CFArrayRef (*)(void *))dlsym(mWifiHandle, "WiFiManagerClientCopyDevices");
    if (!mWifiGetPower)
        mWifiGetPower = (int (*)(void *))dlsym(mWifiHandle, "WiFiDeviceClientGetPower");
    if (!mWifiSetPower)
        mWifiSetPower = (void (*)(void *, int))dlsym(mWifiHandle, "WiFiDeviceClientSetPower");
    if (!mWifiSetProperty)
        mWifiSetProperty = (void (*)(void *, CFStringRef, CFPropertyListRef))dlsym(mWifiHandle, "WiFiManagerClientSetProperty");
    if (!mWifiCreate || !mWifiCopyDevices || !mWifiGetPower || (!mWifiSetPower && !mWifiSetProperty)) {
        mWifiError = @"mobilewifi-symbols-unavailable";
        return NO;
    }
    if (!mWifiManager)
        mWifiManager = mWifiCreate(kCFAllocatorDefault, 0);
    if (mWifiManager) {
        CFArrayRef devices = mWifiCopyDevices(mWifiManager);
        if (devices && CFArrayGetCount(devices) > 0) {
            mWifiDevice = (void *)CFArrayGetValueAtIndex(devices, 0);
            if (mWifiDevice)
                CFRetain((CFTypeRef)mWifiDevice);
        }
        if (devices)
            CFRelease(devices);
    }
    if (!mWifiManager || !mWifiDevice) {
        mWifiError = @"mobilewifi-device-unavailable";
        return NO;
    }
    mWifiError = nil;
    return YES;
}

- (void)dealloc {
    if (mWifiDevice)
        CFRelease((CFTypeRef)mWifiDevice);
    if (mWifiManager)
        CFRelease((CFTypeRef)mWifiManager);
    if (mWifiHandle)
        dlclose(mWifiHandle);
}

- (NSDictionary *)wifiStatus {
    if (![NSThread isMainThread]) {
        __block NSDictionary *status = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ status = [self wifiStatus]; });
        return status;
    }
    if (![self prepareWifi])
        return @{ @"supported" : @NO, @"state" : @"unknown", @"reason" : mWifiError };
    return @{ @"supported" : @YES, @"state" : mWifiGetPower(mWifiDevice) ? @"on" : @"off" };
}

- (BOOL)setWifiEnabled:(BOOL)enabled error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        __block NSError *mainError = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self setWifiEnabled:enabled error:&mainError]; });
        if (!result && error)
            *error = mainError;
        return result;
    }
    if (![self prepareWifi]) {
        if (error)
            *error = [NSError errorWithDomain:IRDeviceServicesErrorDomain code:1
                                      userInfo:@{NSLocalizedDescriptionKey : mWifiError}];
        return NO;
    }
    if (mWifiSetProperty)
        mWifiSetProperty(mWifiManager, CFSTR("AllowEnable"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
    if (mWifiSetPower)
        mWifiSetPower(mWifiDevice, enabled ? 1 : 0);
    BOOL actual = mWifiGetPower(mWifiDevice) != 0;
    for (NSUInteger attempt = 0; attempt < 20 && actual != enabled; attempt++) {
        usleep(100000);
        actual = mWifiGetPower(mWifiDevice) != 0;
    }
    if (actual != enabled) {
        if (error)
            *error = [NSError errorWithDomain:IRDeviceServicesErrorDomain code:2
                                      userInfo:@{NSLocalizedDescriptionKey : @"wifi-state-verification-failed"}];
        return NO;
    }
    return YES;
}

- (NSString *)sysctlString:(const char *)name {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0)
        return @"unknown";
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (sysctlbyname(name, data.mutableBytes, &size, NULL, 0) != 0)
        return @"unknown";
    NSString *value = [NSString stringWithUTF8String:(const char *)data.bytes];
    return value ?: @"unknown";
}

- (NSDictionary *)deviceInfo {
    UIDevice *device = UIDevice.currentDevice;
    return @{
        @"model" : [self sysctlString:"hw.machine"],
        @"name" : device.name ?: @"iPhone",
        @"systemName" : device.systemName ?: @"iOS",
        @"systemVersion" : device.systemVersion ?: @"unknown",
        @"architecture" : [self sysctlString:"hw.machine"],
    };
}

- (NSArray<NSDictionary *> *)installedApplicationsWithError:(NSError **)error {
    dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW | RTLD_GLOBAL);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    SEL listSelector = NSSelectorFromString(@"allInstalledApplications");
    id (*sendId)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
    id workspace = workspaceClass && [workspaceClass respondsToSelector:defaultSelector]
                       ? sendId((id)workspaceClass, defaultSelector)
                       : nil;
    NSArray *proxies = workspace && [workspace respondsToSelector:listSelector] ? sendId(workspace, listSelector) : nil;
    if (![proxies isKindOfClass:NSArray.class]) {
        if (error)
            *error = [NSError errorWithDomain:IRDeviceServicesErrorDomain code:3
                                      userInfo:@{NSLocalizedDescriptionKey : @"LSApplicationWorkspace unavailable"}];
        return nil;
    }
    NSMutableArray *apps = [NSMutableArray arrayWithCapacity:proxies.count];
    for (id proxy in proxies) {
        @try {
            NSString *bundleId = [proxy valueForKey:@"applicationIdentifier"];
            NSString *name = [proxy valueForKey:@"localizedName"];
            NSString *type = [proxy valueForKey:@"applicationType"];
            if (![bundleId isKindOfClass:NSString.class] || bundleId.length == 0)
                continue;
            [apps addObject:@{
                @"bundleId" : bundleId,
                @"name" : [name isKindOfClass:NSString.class] ? name : bundleId,
                @"type" : [type isKindOfClass:NSString.class] ? type.lowercaseString : @"unknown",
            }];
        } @catch (NSException *exception) {
            // Private proxy shapes vary by iOS release; skip unknown records without
            // failing the complete list.
            continue;
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
    }];
    return apps;
}

- (BOOL)launchApplication:(NSString *)bundleIdentifier error:(NSError **)error {
    if (![bundleIdentifier isKindOfClass:NSString.class] || bundleIdentifier.length == 0) {
        if (error)
            *error = [NSError errorWithDomain:IRDeviceServicesErrorDomain code:4
                                      userInfo:@{NSLocalizedDescriptionKey : @"bundleId is required"}];
        return NO;
    }
    dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW | RTLD_GLOBAL);
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    id (*sendId)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
    BOOL (*sendBoolArg)(id, SEL, id) = (BOOL(*)(id, SEL, id))objc_msgSend;
    id workspace = workspaceClass && [workspaceClass respondsToSelector:defaultSelector]
                       ? sendId((id)workspaceClass, defaultSelector)
                       : nil;
    if (!workspace || ![workspace respondsToSelector:openSelector] || !sendBoolArg(workspace, openSelector, bundleIdentifier)) {
        if (error)
            *error = [NSError errorWithDomain:IRDeviceServicesErrorDomain code:5
                                      userInfo:@{NSLocalizedDescriptionKey : @"application launch failed or unsupported"}];
        return NO;
    }
    return YES;
}

@end
