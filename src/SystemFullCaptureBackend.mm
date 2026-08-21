/* GPL-2.0-only */

#import "SystemFullCaptureBackend.h"

#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <time.h>
#include <atomic>

#import "IOSurfaceSPI.h"
#import "Logging.h"
#import "UIScreen+Private.h"

static NSString *const TVSystemFullCaptureErrorDomain = @"com.82flex.trollvnc.capture.system_full";

@implementation SystemFullCaptureBackend {
    NSDictionary *mRenderProperties;
    CADisplayLink *mDisplayLink;
    TVScreenCaptureFrameHandler mFrameHandler;
    dispatch_queue_t mCaptureQueue;
    NSInteger mMinFps;
    NSInteger mPreferredFps;
    NSInteger mMaxFps;
    BOOL mCapturing;
    std::atomic_bool mCaptureInFlight;
    uint64_t mFrames;
    std::atomic_uint64_t mDroppedFrames;
    uint64_t mFrameFailures;
    uint64_t mLastLogTime;
    uint64_t mLastLogFrames;
    uint64_t mLastCaptureDuration;
    Class mScreenClass;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;

    mCaptureQueue = dispatch_queue_create("com.82flex.trollvnc.capture.system_full", DISPATCH_QUEUE_SERIAL);
    mCaptureInFlight.store(false);
    CGSize size = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    int width = (int)round(size.width);
    int height = (int)round(size.height);
    int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, 4 * width);
    mRenderProperties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @4,
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(width),
        (__bridge NSString *)kIOSurfaceHeight : @(height),
        (__bridge NSString *)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bytesPerRow * height),
    };
    return self;
}

- (NSString *)backendName { return @"system_full"; }
- (NSDictionary *)renderProperties { return mRenderProperties; }
- (BOOL)isCapturing { return mCapturing; }

- (BOOL)loadSystemProvider:(NSError **)error {
#if TARGET_OS_SIMULATOR
    NSString *reason = @"SYSTEM_FULL is physical-device only";
#else
    if (mScreenClass)
        return YES;

    const char *frameworks[] = {
        "/System/Library/Frameworks/XCTest.framework/XCTest",
        "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        "/Developer/Library/Frameworks/XCTest.framework/XCTest",
        "/System/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",
        "/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",
        "/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",
    };
    for (size_t index = 0; index < sizeof(frameworks) / sizeof(frameworks[0]); index++)
        dlopen(frameworks[index], RTLD_NOW | RTLD_GLOBAL);

    mScreenClass = NSClassFromString(@"XCUIScreen");
    if (mScreenClass && [mScreenClass respondsToSelector:NSSelectorFromString(@"mainScreen")])
        return YES;
    NSString *reason = @"XCUIScreen unavailable; XCTest/XCUIAutomation is not loadable in this process";
#endif
    TVLog(@"capture.backend=system_full provider=xcui_screen initialization=failed reason=%@", reason);
    if (error)
        *error = [NSError errorWithDomain:TVSystemFullCaptureErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : reason}];
    return NO;
}

- (BOOL)isAvailable {
    return [self loadSystemProvider:nil];
}

- (UIImage *)captureSystemImage:(NSError **)error {
    @try {
        SEL mainScreenSelector = NSSelectorFromString(@"mainScreen");
        SEL screenshotSelector = NSSelectorFromString(@"screenshot");
        SEL imageSelector = NSSelectorFromString(@"image");
        id (*sendId)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
        id screen = sendId((id)mScreenClass, mainScreenSelector);
        if (!screen || ![screen respondsToSelector:screenshotSelector])
            @throw [NSException exceptionWithName:@"TVSystemFullUnavailable"
                                           reason:@"XCUIScreen screenshot selector unavailable"
                                         userInfo:nil];
        id screenshot = sendId(screen, screenshotSelector);
        UIImage *image = screenshot && [screenshot respondsToSelector:imageSelector] ? sendId(screenshot, imageSelector) : nil;
        if (image.CGImage)
            return image;
        @throw [NSException exceptionWithName:@"TVSystemFullEmpty"
                                       reason:@"XCUIScreen returned an empty screenshot"
                                     userInfo:nil];
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        if (error)
            *error = [NSError errorWithDomain:TVSystemFullCaptureErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : reason}];
        return nil;
    }
}

- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler error:(NSError **)error {
    if (![self loadSystemProvider:error])
        return NO;

    __block UIImage *probe = nil;
    __block NSError *probeError = nil;
    dispatch_sync(mCaptureQueue, ^{ probe = [self captureSystemImage:&probeError]; });
    if (!probe) {
        NSString *reason = probeError.localizedDescription ?: @"system screenshot probe failed";
        TVLog(@"capture.backend=system_full provider=xcui_screen initialization=failed reason=%@", reason);
        if (error)
            *error = probeError;
        return NO;
    }

    mFrameHandler = [frameHandler copy];
    mFrames = mFrameFailures = mLastLogTime = mLastLogFrames = 0;
    mDroppedFrames.store(0);
    mCaptureInFlight.store(false);
    void (^startBlock)(void) = ^{
        if (!mDisplayLink) {
            mDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
            [self applyFrameRate];
            [mDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
        mCapturing = YES;
    };
    if (NSThread.isMainThread)
        startBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), startBlock);
    TVLog(@"capture.backend=system_full provider=xcui_screen initialization=success boundedInFlight=1");
    return YES;
}

- (void)endCapture {
    void (^stopBlock)(void) = ^{
        mCapturing = NO;
        [mDisplayLink invalidate];
        mDisplayLink = nil;
        mFrameHandler = nil;
    };
    if (NSThread.isMainThread)
        stopBlock();
    else
        dispatch_async(dispatch_get_main_queue(), stopBlock);
}

- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps {
    mMinFps = MAX(0, minFps);
    mPreferredFps = MAX(0, preferredFps);
    mMaxFps = MAX(0, maxFps);
    if (mPreferredFps == 0)
        mPreferredFps = mMaxFps > 0 ? mMaxFps : mMinFps;
    if (mDisplayLink)
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyFrameRate]; });
}

- (void)forceNextFrameUpdate {}

- (void)applyFrameRate {
    if (!mDisplayLink)
        return;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (@available(iOS 15, *)) {
        CAFrameRateRange range;
        range.minimum = mMinFps > 0 ? mMinFps : 0;
        range.maximum = mMaxFps > 0 ? mMaxFps : 0;
        range.preferred = mPreferredFps > 0 ? mPreferredFps : 0;
        mDisplayLink.preferredFrameRateRange = range;
        return;
    }
#endif
    mDisplayLink.preferredFramesPerSecond = (int)(mMaxFps > 0 ? mMaxFps : mPreferredFps);
}

- (CMSampleBufferRef)newSampleBufferFromImage:(UIImage *)image timestamp:(CFTimeInterval)timestamp duration:(CFTimeInterval)duration {
    size_t width = [mRenderProperties[(__bridge NSString *)kIOSurfaceWidth] unsignedIntegerValue];
    size_t height = [mRenderProperties[(__bridge NSString *)kIOSurfaceHeight] unsignedIntegerValue];
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &pixelBuffer) != kCVReturnSuccess)
        return NULL;
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer), width, height, 8,
                                                 CVPixelBufferGetBytesPerRow(pixelBuffer), colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) {
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if (!context) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    CMSampleTimingInfo timing = {
        .duration = CMTimeMakeWithSeconds(duration, 1000000000),
        .presentationTimeStamp = CMTimeMakeWithSeconds(timestamp, 1000000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, format, &timing, &sample);
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);
    return sample;
}

- (void)onDisplayLink:(CADisplayLink *)link {
    if (!mCapturing || !mFrameHandler)
        return;
    bool expected = false;
    if (!mCaptureInFlight.compare_exchange_strong(expected, true)) {
        mDroppedFrames.fetch_add(1);
        return;
    }
    CFTimeInterval timestamp = link.timestamp;
    CFTimeInterval duration = link.duration;
    dispatch_async(mCaptureQueue, ^{
        uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        NSError *captureError = nil;
        UIImage *image = [self captureSystemImage:&captureError];
        CMSampleBufferRef sample = image ? [self newSampleBufferFromImage:image timestamp:timestamp duration:duration] : NULL;
        if (sample) {
            TVScreenCaptureFrameHandler handler = mFrameHandler;
            if (handler)
                handler(sample);
            CFRelease(sample);
            mFrames++;
        } else {
            mFrameFailures++;
            if (mFrameFailures <= 3 || mFrameFailures % 30 == 0)
                TVLog(@"capture.backend=system_full frameFailure=%llu reason=%@", mFrameFailures,
                      captureError.localizedDescription ?: @"conversion_failed");
        }
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        mLastCaptureDuration = now - started;
        if (mLastLogTime == 0 || now - mLastLogTime >= 5ULL * NSEC_PER_SEC) {
            double seconds = mLastLogTime ? (double)(now - mLastLogTime) / NSEC_PER_SEC : 0;
            double fps = seconds > 0 ? (double)(mFrames - mLastLogFrames) / seconds : 0;
            TVLog(@"capture.backend=system_full durationMs=%.2f frameWidth=%@ frameHeight=%@ captureFPS=%.2f "
                   "droppedFrames=%llu frameFailures=%llu",
                  (double)mLastCaptureDuration / NSEC_PER_MSEC,
                  mRenderProperties[(__bridge NSString *)kIOSurfaceWidth],
                  mRenderProperties[(__bridge NSString *)kIOSurfaceHeight], fps, mDroppedFrames.load(), mFrameFailures);
            mLastLogTime = now;
            mLastLogFrames = mFrames;
        }
        mCaptureInFlight.store(false);
    });
}

@end
