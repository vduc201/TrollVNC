/* GPL-2.0-only */

#ifndef UIKitFullCaptureBackend_h
#define UIKitFullCaptureBackend_h

#import "IScreenCaptureBackend.h"

NS_ASSUME_NONNULL_BEGIN

/**
 UIKIT_FULL capture using UIKit's process-external screen image facility when
 that private symbol is present in the current iOS runtime. Availability and
 every capture result are checked at runtime; this backend never fabricates a
 frame or silently substitutes the fast backend.
 */
@interface UIKitFullCaptureBackend : NSObject <IScreenCaptureBackend>
@end

NS_ASSUME_NONNULL_END

#endif /* UIKitFullCaptureBackend_h */
