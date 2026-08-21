/* GPL-2.0-only */

#ifndef CaptureManager_h
#define CaptureManager_h

#import "IScreenCaptureBackend.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TVCaptureMode) {
    TVCaptureModeFast = 0,
    TVCaptureModeUIKitFull,
    TVCaptureModeSystemFull,
};

FOUNDATION_EXPORT NSString *TVCaptureModeName(TVCaptureMode mode);
FOUNDATION_EXPORT BOOL TVCaptureModeParse(NSString *value, TVCaptureMode *mode);

@interface CaptureManager : NSObject

+ (instancetype)sharedManager;

@property(nonatomic, readonly) TVCaptureMode mode;
@property(nonatomic, copy, readonly) NSString *activeBackendName;
@property(nonatomic, strong, readonly) NSDictionary *renderProperties;
@property(nonatomic, readonly, getter=isCapturing) BOOL capturing;

- (BOOL)setMode:(TVCaptureMode)mode error:(NSError *_Nullable *_Nullable)error;
- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler
                               error:(NSError *_Nullable *_Nullable)error;
- (void)endCapture;
- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps;
- (void)forceNextFrameUpdate;

@end

NS_ASSUME_NONNULL_END

#endif /* CaptureManager_h */
