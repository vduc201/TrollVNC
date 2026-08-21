/* GPL-2.0-only */

#import "FastCaptureBackend.h"

#import "ScreenCapturer.h"
#import "Logging.h"

@implementation FastCaptureBackend {
    BOOL mCapturing;
}

- (NSString *)backendName {
    return @"fast";
}

- (NSDictionary *)renderProperties {
    return [ScreenCapturer sharedCapturer].renderProperties;
}

- (BOOL)isAvailable {
    return YES;
}

- (BOOL)isCapturing {
    return mCapturing;
}

- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler error:(NSError **)error {
    (void)error;
    [[ScreenCapturer sharedCapturer] startCaptureWithFrameHandler:frameHandler];
    mCapturing = YES;
    TVLog(@"capture.backend=fast initialization=success provider=CARenderServerRenderDisplay");
    return YES;
}

- (void)endCapture {
    [[ScreenCapturer sharedCapturer] endCapture];
    mCapturing = NO;
}

- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps {
    [[ScreenCapturer sharedCapturer] setPreferredFrameRateWithMin:minFps preferred:preferredFps max:maxFps];
}

- (void)forceNextFrameUpdate {
    [[ScreenCapturer sharedCapturer] forceNextFrameUpdate];
}

@end
