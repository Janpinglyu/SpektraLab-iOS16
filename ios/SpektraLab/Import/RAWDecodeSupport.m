#import "RAWDecodeSupport.h"

#import <CoreImage/CIRAWFilter.h>

static void SPKTrySetter(NSString *name, void (^body)(void)) {
    @try {
        body();
    } @catch (NSException *exception) {
        NSLog(@"SpektraLab RAW option %@ unavailable: %@", name, exception.reason);
    }
}

CIImage *SPKDecodeRAWImage(NSData *data, NSString *identifierHint) {
    @try {
        CIRAWFilter *raw = [CIRAWFilter filterWithImageData:data
                                            identifierHint:identifierHint];
        if (raw == nil) {
            return nil;
        }

        SPKTrySetter(@"lens correction", ^{
            if (raw.isLensCorrectionSupported) {
                raw.lensCorrectionEnabled = NO;
            }
        });
        SPKTrySetter(@"draft mode", ^{
            raw.draftModeEnabled = NO;
        });
        SPKTrySetter(@"boost", ^{
            raw.boostAmount = 0;
        });
        SPKTrySetter(@"shadow boost", ^{
            raw.boostShadowAmount = 0;
        });
        SPKTrySetter(@"gamut mapping", ^{
            raw.gamutMappingEnabled = NO;
        });
        SPKTrySetter(@"local tone map", ^{
            raw.localToneMapAmount = 0;
        });
        SPKTrySetter(@"extended dynamic range", ^{
            raw.extendedDynamicRangeAmount = 0;
        });

        CIImage *output = raw.outputImage;
        if (output == nil) {
            return nil;
        }

        // iOS sometimes returns an embedded preview instead of the sensor
        // frame. NEF hits this on iOS 27: the output is 120x160 while the
        // filter's own nativeSize is 6048x4024. Reporting nil sends the file
        // to the LibRaw fallback, which decodes the real frame.
        const CGSize nativeSize = raw.nativeSize;
        const CGRect extent = output.extent;
        if (getenv("SPEKTRAFILM_RAW_LOG") != NULL) {
            NSLog(@"SpektraLab RAW filter native=%.0fx%.0f extent=%.0fx%.0f scale=%.3f",
                  nativeSize.width, nativeSize.height,
                  extent.size.width, extent.size.height, raw.scaleFactor);
        }
        const CGFloat nativeLongEdge = MAX(nativeSize.width, nativeSize.height);
        const CGFloat outputLongEdge = MAX(extent.size.width, extent.size.height);
        if (nativeLongEdge > 0 && outputLongEdge > 0 &&
            outputLongEdge < nativeLongEdge * 0.5) {
            NSLog(@"SpektraLab Core Image RAW returned %.0fx%.0f for a %.0fx%.0f frame",
                  extent.size.width, extent.size.height,
                  nativeSize.width, nativeSize.height);
            return nil;
        }
        return output;
    } @catch (NSException *exception) {
        NSLog(@"SpektraLab could not decode RAW: %@", exception.reason);
        return nil;
    }
}
