/* GPL-2.0-only */

#import "CaptureManager.h"

#import "FastCaptureBackend.h"
#import "FullCaptureBackend.h"
#import "Logging.h"

static NSString *const TVCaptureManagerErrorDomain = @"com.82flex.trollvnc.capture";

NSString *TVCaptureModeName(TVCaptureMode mode) {
    switch (mode) {
    case TVCaptureModeFull:
        return @"full";
    case TVCaptureModeAuto:
        return @"auto";
    case TVCaptureModeFast:
    default:
        return @"fast";
    }
}

BOOL TVCaptureModeParse(NSString *value, TVCaptureMode *mode) {
    NSString *normalized = value.lowercaseString;
    TVCaptureMode parsed;
    if ([normalized isEqualToString:@"fast"])
        parsed = TVCaptureModeFast;
    else if ([normalized isEqualToString:@"full"])
        parsed = TVCaptureModeFull;
    else if ([normalized isEqualToString:@"auto"])
        parsed = TVCaptureModeAuto;
    else
        return NO;
    if (mode)
        *mode = parsed;
    return YES;
}

@implementation CaptureManager {
    id<IScreenCaptureBackend> mFastBackend;
    id<IScreenCaptureBackend> mFullBackend;
    id<IScreenCaptureBackend> mActiveBackend;
    TVCaptureMode mMode;
    TVScreenCaptureFrameHandler mFrameHandler;
    NSInteger mMinFps;
    NSInteger mPreferredFps;
    NSInteger mMaxFps;
}

+ (instancetype)sharedManager {
    static CaptureManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;
    mFastBackend = [[FastCaptureBackend alloc] init];
    mFullBackend = [[FullCaptureBackend alloc] init];
    mMode = TVCaptureModeFast;
    mActiveBackend = mFastBackend;
    return self;
}

- (TVCaptureMode)mode {
    return mMode;
}

- (NSString *)activeBackendName {
    return mActiveBackend.backendName;
}

- (NSDictionary *)renderProperties {
    return mActiveBackend.renderProperties;
}

- (BOOL)isCapturing {
    return mActiveBackend.capturing;
}

- (id<IScreenCaptureBackend>)backendForMode:(TVCaptureMode)mode {
    // AUTO begins conservatively on FAST. Evidence-based switching is added in Phase C.
    return mode == TVCaptureModeFull ? mFullBackend : mFastBackend;
}

- (BOOL)setMode:(TVCaptureMode)mode error:(NSError **)error {
    id<IScreenCaptureBackend> next = [self backendForMode:mode];
    if (!next.available) {
        if (error) {
            *error = [NSError errorWithDomain:TVCaptureManagerErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey :
                                                    [NSString stringWithFormat:@"%@ capture backend unavailable",
                                                                               next.backendName]}];
        }
        return NO;
    }
    if (next == mActiveBackend) {
        mMode = mode;
        return YES;
    }

    BOOL wasCapturing = mActiveBackend.capturing;
    if (wasCapturing)
        [mActiveBackend endCapture];
    [next setPreferredFrameRateWithMin:mMinFps preferred:mPreferredFps max:mMaxFps];
    if (wasCapturing && ![next startCaptureWithFrameHandler:mFrameHandler error:error]) {
        NSError *rollbackError = nil;
        [mActiveBackend startCaptureWithFrameHandler:mFrameHandler error:&rollbackError];
        return NO;
    }
    NSString *previous = mActiveBackend.backendName;
    mActiveBackend = next;
    mMode = mode;
    TVLog(@"capture backend switch previous=%@ active=%@ mode=%@", previous, next.backendName,
          TVCaptureModeName(mode));
    return YES;
}

- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler error:(NSError **)error {
    mFrameHandler = [frameHandler copy];
    return [mActiveBackend startCaptureWithFrameHandler:mFrameHandler error:error];
}

- (void)endCapture {
    [mActiveBackend endCapture];
}

- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps {
    mMinFps = minFps;
    mPreferredFps = preferredFps;
    mMaxFps = maxFps;
    [mFastBackend setPreferredFrameRateWithMin:minFps preferred:preferredFps max:maxFps];
    [mFullBackend setPreferredFrameRateWithMin:minFps preferred:preferredFps max:maxFps];
}

- (void)forceNextFrameUpdate {
    [mActiveBackend forceNextFrameUpdate];
}

@end
