/*
 This file is part of TrollShot, derived from TrollVNC.
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import "ScreenCapturer.h"
#import "IOSurfaceSPI.h"
#import "UIScreen+Private.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

CFIndex CARenderServerGetDirtyFrameCount(void *);
void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

#ifdef __cplusplus
}
#endif

@implementation ScreenCapturer {
    NSDictionary *mRenderProperties;
    IOSurfaceRef mScreenSurface;
}

+ (instancetype)sharedCapturer {
    static ScreenCapturer *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;

    CGSize screenSize = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    int width = (int)round(screenSize.width);
    int height = (int)round(screenSize.height);

    /* ARGB, 8 bits per component, 32 bits per pixel */
    unsigned pixelFormat = 0x42475241; // 'ARGB'
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = bytesPerComponent * 4;
    int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * width);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFPropertyListRef colorSpacePropertyList = CGColorSpaceCopyPropertyList(colorSpace);
    CGColorSpaceRelease(colorSpace);

    mRenderProperties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(width),
        (__bridge NSString *)kIOSurfaceHeight : @(height),
        (__bridge NSString *)kIOSurfacePixelFormat : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bytesPerRow * height),
        (__bridge NSString *)kIOSurfaceColorSpace : CFBridgingRelease(colorSpacePropertyList),
    };

    mScreenSurface = IOSurfaceCreate((__bridge CFDictionaryRef)mRenderProperties);
    return self;
}

- (NSData *)captureJPEGWithQuality:(CGFloat)quality error:(NSError **)error {
    if (quality < 0.0)
        quality = 0.0;
    if (quality > 1.0)
        quality = 1.0;

    static IOSurfaceRef srcSurface = NULL;
    static IOSurfaceAcceleratorRef accelerator = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        srcSurface = IOSurfaceCreate((__bridge CFDictionaryRef)mRenderProperties);
        IOSurfaceAcceleratorCreate(kCFAllocatorDefault, nil, &accelerator);
    });

    /* Render the main display into an IOSurface. */
    CARenderServerRenderDisplay(0, CFSTR("LCD"), srcSurface, 0, 0);

    /* Convert to sRGB-compatible surface. */
    IOReturn accelRet = IOSurfaceAcceleratorTransferSurface(accelerator, srcSurface, mScreenSurface, NULL, NULL, NULL, NULL);
    if (accelRet != kIOReturnSuccess) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:1 userInfo:@{NSLocalizedDescriptionKey : @"IOSurface accelerator transfer failed"}];
        return nil;
    }

    /* Wrap the IOSurface as a CVPixelBuffer (zero-copy). */
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVReturn cvret = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, mScreenSurface,
                                                      (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (cvret != kCVReturnSuccess || !pixelBuffer) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:2 userInfo:@{NSLocalizedDescriptionKey : @"CVPixelBuffer creation failed"}];
        return nil;
    }

    /* Use CoreImage to normalize the ARGB buffer into a CGImage. */
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CIContext *ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    CGImageRef cgImage = [ciContext createCGImage:ciImage fromRect:[ciImage extent]];

    NSData *jpegData = nil;
    if (cgImage) {
        NSMutableData *data = [NSMutableData data];
        CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kUTTypeJPEG, 1, NULL);
        if (dest) {
            NSDictionary *props = @{
                (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(quality),
            };
            CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)props);
            if (CGImageDestinationFinalize(dest)) {
                jpegData = [data copy];
            }
            CFRelease(dest);
        }
        CGImageRelease(cgImage);
    }

    CVPixelBufferRelease(pixelBuffer);

    if (!jpegData && error) {
        *error = [NSError errorWithDomain:@"TrollShot" code:3 userInfo:@{NSLocalizedDescriptionKey : @"JPEG encoding failed"}];
    }
    return jpegData;
}

@end
