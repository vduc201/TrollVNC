/* GPL-2.0-only */

#import "IRDeviceServices.h"

#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <unistd.h>

static NSString *const IRDeviceServicesErrorDomain = @"com.82flex.trollvnc.device-services";

@implementation IRDeviceServices {
    void *mWifiHandle;
    void *mWifiManager;
    void *mWifiDevice;
    void *(*mWifiCreate)(CFAllocatorRef, int);
    void *(*mWifiGetDevice)(void *);
    int (*mWifiGetPower)(void *);
    void (*mWifiSetPower)(void *, int);
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
    if (!self)
        return nil;
    mWifiHandle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW | RTLD_LOCAL);
    if (!mWifiHandle) {
        mWifiError = @"mobilewifi-framework-unavailable";
        return self;
    }
    mWifiCreate = (void *(*)(CFAllocatorRef, int))dlsym(mWifiHandle, "WiFiManagerClientCreate");
    mWifiGetDevice = (void *(*)(void *))dlsym(mWifiHandle, "WiFiManagerClientGetDevice");
    mWifiGetPower = (int (*)(void *))dlsym(mWifiHandle, "WiFiDeviceClientGetPower");
    mWifiSetPower = (void (*)(void *, int))dlsym(mWifiHandle, "WiFiDeviceClientSetPower");
    if (!mWifiCreate || !mWifiGetDevice || !mWifiGetPower || !mWifiSetPower) {
        mWifiError = @"mobilewifi-symbols-unavailable";
        return self;
    }
    mWifiManager = mWifiCreate(kCFAllocatorDefault, 0);
    mWifiDevice = mWifiManager ? mWifiGetDevice(mWifiManager) : NULL;
    if (!mWifiManager || !mWifiDevice)
        mWifiError = @"mobilewifi-device-unavailable";
    return self;
}

- (void)dealloc {
    if (mWifiManager)
        CFRelease((CFTypeRef)mWifiManager);
    if (mWifiHandle)
        dlclose(mWifiHandle);
}

- (NSDictionary *)wifiStatus {
    if (mWifiError)
        return @{ @"supported" : @NO, @"state" : @"unknown", @"reason" : mWifiError };
    return @{ @"supported" : @YES, @"state" : mWifiGetPower(mWifiDevice) ? @"on" : @"off" };
}

- (BOOL)setWifiEnabled:(BOOL)enabled error:(NSError **)error {
    if (mWifiError) {
        if (error)
            *error = [NSError errorWithDomain:IRDeviceServicesErrorDomain code:1
                                      userInfo:@{NSLocalizedDescriptionKey : mWifiError}];
        return NO;
    }
    mWifiSetPower(mWifiDevice, enabled ? 1 : 0);
    usleep(200000);
    BOOL actual = mWifiGetPower(mWifiDevice) != 0;
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
