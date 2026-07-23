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
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

CFIndex CARenderServerGetDirtyFrameCount(void *);
/* 将主显示屏内容渲染到 IOSurface */
void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

#ifdef __cplusplus
}
#endif

@implementation ScreenCapturer {
    NSDictionary *mRenderProperties;
    IOSurfaceRef mScreenSurface;
    IOSurfaceRef mSrcSurface;
    IOSurfaceAcceleratorRef mAccelerator;
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

    /* ARGB，每个通道 8 位，每像素 32 位 */
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

    /* 创建源 surface 和加速器；在主线程初始化并将加速器 run loop source 挂到主 run loop */
    mSrcSurface = IOSurfaceCreate((__bridge CFDictionaryRef)mRenderProperties);
    IOReturn accelCreateRet = IOSurfaceAcceleratorCreate(kCFAllocatorDefault, NULL, &mAccelerator);
    if (accelCreateRet == kIOReturnSuccess && mAccelerator) {
        CFRunLoopSourceRef runLoopSource = IOSurfaceAcceleratorGetRunLoopSource(mAccelerator);
        if (runLoopSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode);
        }
    }

    return self;
}

- (NSData *)captureJPEGWithQuality:(CGFloat)quality error:(NSError **)error {
    if (quality < 0.0)
        quality = 0.0;
    if (quality > 1.0)
        quality = 1.0;

    if (!mSrcSurface || !mAccelerator) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:4 userInfo:@{NSLocalizedDescriptionKey : @"IOSurface 加速器未初始化"}];
        return nil;
    }

    /* 把主显示屏内容渲染进 IOSurface */
    CARenderServerRenderDisplay(0, CFSTR("LCD"), mSrcSurface, 0, 0);

    /* 转换成与 sRGB 兼容的 surface */
    IOReturn accelRet = IOSurfaceAcceleratorTransferSurface(mAccelerator, mSrcSurface, mScreenSurface, NULL, NULL, NULL, NULL);
    if (accelRet != kIOReturnSuccess) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:1 userInfo:@{NSLocalizedDescriptionKey : @"IOSurface 加速器转换失败"}];
        return nil;
    }

    /* 将 IOSurface 零拷贝包装为 CVPixelBuffer */
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{(NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVReturn cvret = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, mScreenSurface,
                                                      (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (cvret != kCVReturnSuccess || !pixelBuffer) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:2 userInfo:@{NSLocalizedDescriptionKey : @"CVPixelBuffer 创建失败"}];
        return nil;
    }

    /* 用 CoreImage 将 ARGB 缓冲区转为 CGImage */
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CIContext *ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    CGImageRef cgImage = [ciContext createCGImage:ciImage fromRect:[ciImage extent]];

    NSData *jpegData = nil;
    if (cgImage) {
        NSMutableData *data = [NSMutableData data];
        /* 用 Uniform Type Identifier public.jpeg 作为图像格式 */
        CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
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
        *error = [NSError errorWithDomain:@"TrollShot" code:3 userInfo:@{NSLocalizedDescriptionKey : @"JPEG 编码失败"}];
    }
    return jpegData;
}

@end
