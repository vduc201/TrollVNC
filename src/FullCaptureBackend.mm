/* GPL-2.0-only */

#import "FullCaptureBackend.h"

#import <CoreVideo/CoreVideo.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <time.h>

#import "IOSurfaceSPI.h"
#import "Logging.h"
#import "UIScreen+Private.h"

static NSString *const TVFullCaptureErrorDomain = @"com.82flex.trollvnc.capture.uikit_full";

typedef UIImage *_Nullable (*TVCreateScreenImageFunction)(void);

@implementation UIKitFullCaptureBackend {
    TVCreateScreenImageFunction mCreateScreenImage;
    NSDictionary *mRenderProperties;
    CADisplayLink *mDisplayLink;
    TVScreenCaptureFrameHandler mFrameHandler;
    NSInteger mMinFps;
    NSInteger mPreferredFps;
    NSInteger mMaxFps;
    BOOL mCapturing;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;

#if TARGET_OS_SIMULATOR
    mCreateScreenImage = NULL;
#else
    mCreateScreenImage = (TVCreateScreenImageFunction)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
#endif

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

- (NSString *)backendName {
    return @"uikit_full";
}

- (NSDictionary *)renderProperties {
    return mRenderProperties;
}

- (BOOL)isAvailable {
    return mCreateScreenImage != NULL;
}

- (BOOL)isCapturing {
    return mCapturing;
}

- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler error:(NSError **)error {
    if (!self.available) {
        if (error) {
            *error = [NSError errorWithDomain:TVFullCaptureErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"_UICreateScreenUIImage is unavailable"}];
        }
        TVLog(@"capture.backend=uikit_full initialization=failed reason=_UICreateScreenUIImage_unavailable");
        return NO;
    }

    mFrameHandler = [frameHandler copy];
    if (mDisplayLink) {
        mCapturing = YES;
        return YES;
    }

    void (^startBlock)(void) = ^{
        mDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
        [self applyFrameRate];
        [mDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        mCapturing = YES;
    };
    if (NSThread.isMainThread)
        startBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), startBlock);
    TVLog(@"capture.backend=uikit_full initialization=success provider=_UICreateScreenUIImage");
    return YES;
}

- (void)endCapture {
    void (^stopBlock)(void) = ^{
        [mDisplayLink invalidate];
        mDisplayLink = nil;
        mFrameHandler = nil;
        mCapturing = NO;
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

    if (mDisplayLink) {
        if (NSThread.isMainThread)
            [self applyFrameRate];
        else
            dispatch_async(dispatch_get_main_queue(), ^{ [self applyFrameRate]; });
    }
}

- (void)forceNextFrameUpdate {
    // UIKIT_FULL emits every successful frame, so no dirty flag is needed.
}

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

- (void)onDisplayLink:(CADisplayLink *)link {
    if (!mFrameHandler || !mCreateScreenImage)
        return;

    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    UIImage *image = mCreateScreenImage();
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        TVLog(@"capture.backend=uikit_full frameFailure=empty_image");
        return;
    }

    size_t width = [mRenderProperties[(__bridge NSString *)kIOSurfaceWidth] unsignedIntegerValue];
    size_t height = [mRenderProperties[(__bridge NSString *)kIOSurfaceHeight] unsignedIntegerValue];
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (result != kCVReturnSuccess || !pixelBuffer)
        return;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(base, width, height, 8, rowBytes, colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) {
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(colorSpace);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if (!context) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format);
    if (status != noErr || !format) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMakeWithSeconds(link.duration, 1000000000),
        .presentationTimeStamp = CMTimeMakeWithSeconds(link.timestamp, 1000000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, format, &timing,
                                                &sample);
    if (status == noErr && sample)
        mFrameHandler(sample);

    if (sample)
        CFRelease(sample);
    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);

    double durationMs = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1000000.0;
    static uint64_t lastLog = 0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (lastLog == 0 || now - lastLog >= 5ULL * 1000000000ULL) {
        TVLog(@"capture.backend=uikit_full durationMs=%.2f frameWidth=%zu frameHeight=%zu", durationMs, width,
              height);
        lastLog = now;
    }
}

@end
