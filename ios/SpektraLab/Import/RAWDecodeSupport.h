#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/// Decode a camera RAW container through Core Image with Apple's display
/// rendering disabled, so the spectral engine receives the sensor's response.
///
/// The concrete CIRAWFilter implementation varies with the camera format and
/// iOS version, and some implementations do not expose every settable
/// property. Objective-C catches that exception where Swift cannot, keeping
/// an unsupported property from terminating the app during import.
CIImage * _Nullable SPKDecodeRAWImage(NSData *data, NSString * _Nullable identifierHint);

NS_ASSUME_NONNULL_END
