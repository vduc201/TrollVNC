/* GPL-2.0-only */

#import "CaptureManager.h"

#import <QuartzCore/QuartzCore.h>

#import "FastCaptureBackend.h"
#import "FullCaptureBackend.h"
#import "IOSurfaceSPI.h"
#import "Logging.h"
#import "SystemFullCaptureBackend.h"

static NSString *const TVCaptureManagerErrorDomain = @"com.82flex.trollvnc.capture";

NSString *TVCaptureModeName(TVCaptureMode mode) {
    switch (mode) {
    case TVCaptureModeUIKitFull:
        return @"uikit_full";
    case TVCaptureModeSystemFull:
        return @"system_full";
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
    else if ([normalized isEqualToString:@"uikit_full"] || [normalized isEqualToString:@"full"])
        parsed = TVCaptureModeUIKitFull;
    else if ([normalized isEqualToString:@"system_full"])
        parsed = TVCaptureModeSystemFull;
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
    id<IScreenCaptureBackend> mUIKitFullBackend;
    id<IScreenCaptureBackend> mSystemFullBackend;
    id<IScreenCaptureBackend> mActiveBackend;
    TVCaptureMode mMode;
    TVScreenCaptureFrameHandler mFrameHandler;
    NSInteger mMinFps;
    NSInteger mPreferredFps;
    NSInteger mMaxFps;
    BOOL mCompletenessRequired;
    dispatch_source_t mCompletenessTimer;
    NSUInteger mCompletenessGeneration;
    CFTimeInterval mLastSwitchTime;
    CFTimeInterval mCaptureStartedAt;
    CFTimeInterval mLastFrameAt;
    double mCaptureFPS;
    double mLastDeliveryDurationMs;
    uint64_t mCapturedFrames;
}

static const NSTimeInterval TVAutoMinimumDwellSeconds = 8.0;
static const NSTimeInterval TVAutoSwitchCooldownSeconds = 3.0;

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
    mUIKitFullBackend = [[UIKitFullCaptureBackend alloc] init];
    mSystemFullBackend = [[SystemFullCaptureBackend alloc] init];
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

- (BOOL)isCompletenessRequired {
    @synchronized(self) {
        return mCompletenessRequired;
    }
}

- (NSDictionary *)statusSnapshot {
    @synchronized(self) {
        return @{
            @"configuredMode" : TVCaptureModeName(mMode),
            @"activeBackend" : mActiveBackend.backendName,
            @"capturing" : @(mActiveBackend.capturing),
            @"completenessRequired" : @(mCompletenessRequired),
            @"minimumDwellSeconds" : @(TVAutoMinimumDwellSeconds),
            @"switchCooldownSeconds" : @(TVAutoSwitchCooldownSeconds),
            @"captureFPS" : @(mCaptureFPS),
            @"capturedFrames" : @(mCapturedFrames),
            @"captureUptimeSeconds" : @(mCaptureStartedAt > 0 ? CACurrentMediaTime() - mCaptureStartedAt : 0),
            @"lastDeliveryDurationMs" : @(mLastDeliveryDurationMs),
        };
    }
}

- (id<IScreenCaptureBackend>)backendForMode:(TVCaptureMode)mode {
    switch (mode) {
    case TVCaptureModeUIKitFull:
        return mUIKitFullBackend;
    case TVCaptureModeSystemFull:
        return mSystemFullBackend;
    case TVCaptureModeAuto:
        return mFastBackend;
    case TVCaptureModeFast:
    default:
        return mFastBackend;
    }
}

- (BOOL)setMode:(TVCaptureMode)mode error:(NSError **)error {
    @synchronized(self) {
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
        if (mode != TVCaptureModeAuto) {
            mCompletenessRequired = NO;
            mCompletenessGeneration++;
            if (mCompletenessTimer) {
                dispatch_source_cancel(mCompletenessTimer);
                mCompletenessTimer = nil;
            }
        }
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
    mLastSwitchTime = CACurrentMediaTime();
    if (mode != TVCaptureModeAuto) {
        mCompletenessRequired = NO;
        mCompletenessGeneration++;
        if (mCompletenessTimer) {
            dispatch_source_cancel(mCompletenessTimer);
            mCompletenessTimer = nil;
        }
    }
    TVLog(@"capture.backend=%@ previous=%@ mode=%@ switch=success", next.backendName, previous,
          TVCaptureModeName(mode));
    return YES;
    }
}

- (BOOL)switchAutoBackend:(id<IScreenCaptureBackend>)next reason:(NSString *)reason error:(NSError **)error {
    @synchronized(self) {
        if (mMode != TVCaptureModeAuto) {
            if (error)
                *error = [NSError errorWithDomain:TVCaptureManagerErrorDomain code:2
                                          userInfo:@{NSLocalizedDescriptionKey : @"AUTO mode is not active"}];
            return NO;
        }
        if (next == mActiveBackend)
            return YES;

        CFTimeInterval now = CACurrentMediaTime();
        if (mLastSwitchTime > 0 && now - mLastSwitchTime < TVAutoSwitchCooldownSeconds) {
            if (error)
                *error = [NSError errorWithDomain:TVCaptureManagerErrorDomain code:3
                                          userInfo:@{NSLocalizedDescriptionKey : @"AUTO switch cooldown is active"}];
            return NO;
        }
        NSDictionary *currentProps = mActiveBackend.renderProperties;
        NSDictionary *nextProps = next.renderProperties;
        NSArray *geometryKeys = @[
            (__bridge NSString *)kIOSurfaceWidth,
            (__bridge NSString *)kIOSurfaceHeight,
            (__bridge NSString *)kIOSurfacePixelFormat,
        ];
        for (NSString *key in geometryKeys) {
            if (![currentProps[key] isEqual:nextProps[key]]) {
                if (error)
                    *error = [NSError errorWithDomain:TVCaptureManagerErrorDomain code:4
                                              userInfo:@{NSLocalizedDescriptionKey : @"AUTO backend geometry mismatch"}];
                return NO;
            }
        }

        BOOL wasCapturing = mActiveBackend.capturing;
        id<IScreenCaptureBackend> previous = mActiveBackend;
        if (wasCapturing)
            [previous endCapture];
        [next setPreferredFrameRateWithMin:mMinFps preferred:mPreferredFps max:mMaxFps];
        NSError *startError = nil;
        if (wasCapturing && ![next startCaptureWithFrameHandler:mFrameHandler error:&startError]) {
            NSError *rollbackError = nil;
            [previous startCaptureWithFrameHandler:mFrameHandler error:&rollbackError];
            TVLog(@"capture.mode=auto switch=failed target=%@ reason=%@ fallback=fast error=%@", next.backendName,
                  reason, startError.localizedDescription);
            if (previous != mFastBackend) {
                [previous endCapture];
                [mFastBackend startCaptureWithFrameHandler:mFrameHandler error:&rollbackError];
                mActiveBackend = mFastBackend;
            }
            if (error)
                *error = startError;
            return NO;
        }
        mActiveBackend = next;
        mLastSwitchTime = now;
        TVLog(@"capture.mode=auto switch=success previous=%@ active=%@ reason=%@ dwell=%.1f cooldown=%.1f",
              previous.backendName, next.backendName, reason, TVAutoMinimumDwellSeconds, TVAutoSwitchCooldownSeconds);
        return YES;
    }
}

- (BOOL)setCompletenessRequired:(BOOL)required leaseSeconds:(NSTimeInterval)leaseSeconds error:(NSError **)error {
    __block NSUInteger generation = 0;
    @synchronized(self) {
        if (mMode != TVCaptureModeAuto) {
            if (error)
                *error = [NSError errorWithDomain:TVCaptureManagerErrorDomain code:2
                                          userInfo:@{NSLocalizedDescriptionKey : @"Completeness leases require AUTO mode"}];
            return NO;
        }
        mCompletenessRequired = required;
        generation = ++mCompletenessGeneration;
        if (mCompletenessTimer) {
            dispatch_source_cancel(mCompletenessTimer);
            mCompletenessTimer = nil;
        }
    }

    if (required) {
        BOOL switched = [self switchAutoBackend:mSystemFullBackend reason:@"completeness_lease" error:error];
        if (!switched) {
            @synchronized(self) {
                if (generation == mCompletenessGeneration)
                    mCompletenessRequired = NO;
            }
            return NO;
        }
        NSTimeInterval boundedLease = MIN(MAX(leaseSeconds, TVAutoMinimumDwellSeconds), 300.0);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(boundedLease * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{
            @synchronized(self) {
                if (generation != mCompletenessGeneration)
                    return;
                mCompletenessRequired = NO;
                if (mCompletenessTimer)
                    dispatch_source_cancel(mCompletenessTimer);
                mCompletenessTimer = nil;
            }
            NSError *returnError = nil;
            if (![self switchAutoBackend:mFastBackend reason:@"completeness_lease_expired" error:&returnError])
                TVLog(@"capture.mode=auto returnToFast=pending error=%@", returnError.localizedDescription);
        });
        @synchronized(self) { mCompletenessTimer = timer; }
        dispatch_resume(timer);
        return YES;
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - mLastSwitchTime;
    NSTimeInterval delay = MAX(0, TVAutoMinimumDwellSeconds - elapsed);
    if (delay > 0) {
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{
            @synchronized(self) {
                if (generation != mCompletenessGeneration)
                    return;
            }
            NSError *returnError = nil;
            [self switchAutoBackend:mFastBackend reason:@"minimum_dwell_complete" error:&returnError];
            @synchronized(self) {
                if (mCompletenessTimer)
                    dispatch_source_cancel(mCompletenessTimer);
                mCompletenessTimer = nil;
            }
        });
        @synchronized(self) { mCompletenessTimer = timer; }
        dispatch_resume(timer);
        return YES;
    }
    return [self switchAutoBackend:mFastBackend reason:@"completeness_released" error:error];
}

- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler error:(NSError **)error {
    TVScreenCaptureFrameHandler downstream = [frameHandler copy];
    @synchronized(self) {
        mCaptureStartedAt = CACurrentMediaTime();
        mLastFrameAt = 0;
        mCaptureFPS = 0;
        mLastDeliveryDurationMs = 0;
        mCapturedFrames = 0;
    }
    mFrameHandler = ^(CMSampleBufferRef sampleBuffer) {
        CFTimeInterval receivedAt = CACurrentMediaTime();
        @synchronized(self) {
            if (mLastFrameAt > 0) {
                double instantaneousFPS = 1.0 / MAX(receivedAt - mLastFrameAt, 0.000001);
                mCaptureFPS = mCaptureFPS > 0 ? (mCaptureFPS * 0.85 + instantaneousFPS * 0.15) : instantaneousFPS;
            }
            mLastFrameAt = receivedAt;
            mCapturedFrames++;
        }
        downstream(sampleBuffer);
        @synchronized(self) { mLastDeliveryDurationMs = (CACurrentMediaTime() - receivedAt) * 1000.0; }
    };
    BOOL started = [mActiveBackend startCaptureWithFrameHandler:mFrameHandler error:error];
    if (!started) {
        @synchronized(self) { mCaptureStartedAt = 0; }
    }
    return started;
}

- (void)endCapture {
    [mActiveBackend endCapture];
    @synchronized(self) { mCaptureStartedAt = 0; }
}

- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps {
    mMinFps = minFps;
    mPreferredFps = preferredFps;
    mMaxFps = maxFps;
    [mFastBackend setPreferredFrameRateWithMin:minFps preferred:preferredFps max:maxFps];
    [mUIKitFullBackend setPreferredFrameRateWithMin:minFps preferred:preferredFps max:maxFps];
    [mSystemFullBackend setPreferredFrameRateWithMin:minFps preferred:preferredFps max:maxFps];
}

- (void)forceNextFrameUpdate {
    [mActiveBackend forceNextFrameUpdate];
}

@end
