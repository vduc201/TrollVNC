/* GPL-2.0-only */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IRDeviceServices : NSObject
+ (instancetype)sharedServices;
@property(nonatomic, strong, readonly) NSDictionary *wifiStatus;
@property(nonatomic, strong, readonly) NSDictionary *deviceInfo;
- (BOOL)setWifiEnabled:(BOOL)enabled error:(NSError *_Nullable *_Nullable)error;
- (nullable NSArray<NSDictionary *> *)installedApplicationsWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)launchApplication:(NSString *)bundleIdentifier error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
