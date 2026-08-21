/* GPL-2.0-only */

#ifndef SystemFullCaptureBackend_h
#define SystemFullCaptureBackend_h

#import "IScreenCaptureBackend.h"

NS_ASSUME_NONNULL_BEGIN

/** Runtime-checked system screenshot provider backed by XCUIScreen. */
@interface SystemFullCaptureBackend : NSObject <IScreenCaptureBackend>
@end

NS_ASSUME_NONNULL_END

#endif /* SystemFullCaptureBackend_h */
