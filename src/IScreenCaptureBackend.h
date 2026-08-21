/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2.
*/

#ifndef IScreenCaptureBackend_h
#define IScreenCaptureBackend_h

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TVScreenCaptureFrameHandler)(CMSampleBufferRef sampleBuffer);

@protocol IScreenCaptureBackend <NSObject>

@property(nonatomic, copy, readonly) NSString *backendName;
@property(nonatomic, strong, readonly) NSDictionary *renderProperties;
@property(nonatomic, readonly, getter=isAvailable) BOOL available;
@property(nonatomic, readonly, getter=isCapturing) BOOL capturing;

- (BOOL)startCaptureWithFrameHandler:(TVScreenCaptureFrameHandler)frameHandler
                               error:(NSError *_Nullable *_Nullable)error;
- (void)endCapture;
- (void)setPreferredFrameRateWithMin:(NSInteger)minFps preferred:(NSInteger)preferredFps max:(NSInteger)maxFps;
- (void)forceNextFrameUpdate;

@end

NS_ASSUME_NONNULL_END

#endif /* IScreenCaptureBackend_h */
