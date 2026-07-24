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
#import "FBSOrientationObserver.h"

/* 诊断全局变量 */
size_t g_lastOrigWidth = 0;
size_t g_lastOrigHeight = 0;
size_t g_lastFinalWidth = 0;
size_t g_lastFinalHeight = 0;
BOOL g_lastRotated = NO;

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <syslog.h>
#import "TSLogger.h"

/* 调试模式才输出 syslog，避免非调试模式下产生大量系统日志 */
#define TSLog(priority, fmt, ...) do { \
    if ([[TSLogger sharedLogger] debugEnabled]) \
        syslog(priority, fmt, ##__VA_ARGS__); \
} while(0)

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
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
        }
    }

    return self;
}

- (NSData *)captureJPEGWithQuality:(CGFloat)quality rotate:(BOOL)rotate cropRect:(CGRect)cropRect error:(NSError **)error {
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

    /* 用 CoreImage 将 ARGB 缓冲区转为 CGImage（不做旋转，先拿到原始位图） */
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CIContext *ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];
    CGImageRef cgImage = [ciContext createCGImage:ciImage fromRect:[ciImage extent]];

    CVPixelBufferRelease(pixelBuffer);

    /*
     * 方向校正（CGContext 手动旋转）：
     * 使用 FBSOrientationObserver（FrontBoardServices 私有框架）获取当前设备方向。
     * rotate=YES 时强制旋转（手动覆盖，如 ?rotate=1）；
     * rotate=NO 时自动检测：横屏(Landscape)则旋转，竖屏(Portrait)则不旋转。
     * 参考 TrollVNC 的 setupOrientationObserver 方案。
     */
    g_lastRotated = NO;
    g_lastOrigWidth = 0;
    g_lastOrigHeight = 0;
    g_lastFinalWidth = 0;
    g_lastFinalHeight = 0;

    if (cgImage) {
        size_t imgWidth = CGImageGetWidth(cgImage);
        size_t imgHeight = CGImageGetHeight(cgImage);
        g_lastOrigWidth = imgWidth;
        g_lastOrigHeight = imgHeight;
        g_lastFinalWidth = imgWidth;
        g_lastFinalHeight = imgHeight;

        /* 自动检测当前设备方向 */
        BOOL shouldRotate = rotate; /* rotate=YES 强制旋转 */
        if (!shouldRotate) {
            @try {
                FBSOrientationObserver *observer = [[FBSOrientationObserver alloc] init];
                UIInterfaceOrientation orientation = [observer activeInterfaceOrientation];
                TSLog(LOG_NOTICE, "[TrollShot] FBSOrientationObserver: orientation=%ld", (long)orientation);
                if (orientation == UIInterfaceOrientationLandscapeLeft ||
                    orientation == UIInterfaceOrientationLandscapeRight) {
                    shouldRotate = YES;
                }
            } @catch (NSException *e) {
                TSLog(LOG_ERR, "[TrollShot] FBSOrientationObserver exception: %s", [e.reason UTF8String]);
            }
        }

        TSLog(LOG_NOTICE, "[TrollShot] 原始图像尺寸: %zux%zu, shouldRotate=%d", imgWidth, imgHeight, shouldRotate);

        if (shouldRotate && imgHeight > imgWidth) {
            /* 顺时针90°: 平移+旋转，输出宽高互换 */
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL,
                                                      imgHeight,   /* 新宽 = 旧高 */
                                                      imgWidth,    /* 新高 = 旧宽 */
                                                      8, 0, cs,
                                                      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
            CGColorSpaceRelease(cs);
            if (ctx) {
                CGContextTranslateCTM(ctx, imgHeight, 0);
                CGContextRotateCTM(ctx, M_PI_2);
                CGContextDrawImage(ctx, CGRectMake(0, 0, imgWidth, imgHeight), cgImage);
                CGImageRelease(cgImage);
                cgImage = CGBitmapContextCreateImage(ctx);
                CGContextRelease(ctx);
                g_lastRotated = YES;
                if (cgImage) {
                    g_lastFinalWidth = CGImageGetWidth(cgImage);
                    g_lastFinalHeight = CGImageGetHeight(cgImage);
                }
                TSLog(LOG_NOTICE, "[TrollShot] 旋转后图像尺寸: %zux%zu rotated=YES",
                    g_lastFinalWidth, g_lastFinalHeight);
            } else {
                TSLog(LOG_ERR, "[TrollShot] CGBitmapContextCreate 失败! ctx=NULL");
            }
        } else {
            TSLog(LOG_NOTICE, "[TrollShot] 不需要旋转 (shouldRotate=NO), rotated=NO");
        }
    } else {
        TSLog(LOG_ERR, "[TrollShot] cgImage 为 NULL! createCGImage 失败");
    }

    NSData *jpegData = nil;
    if (cgImage) {
        /* 裁剪：基于旋转后的最终图像坐标，cropRect 非空时裁剪指定区域 */
        BOOL hasCrop = !CGRectIsEmpty(cropRect);
        if (hasCrop) {
            size_t finalW = CGImageGetWidth(cgImage);
            size_t finalH = CGImageGetHeight(cgImage);
            CGRect imageRect = CGRectMake(0, 0, finalW, finalH);
            CGRect clampedRect = CGRectIntersection(cropRect, imageRect);
            if (!CGRectIsEmpty(clampedRect)) {
                CGImageRef croppedImage = CGImageCreateWithImageInRect(cgImage, clampedRect);
                if (croppedImage) {
                    CGImageRelease(cgImage);
                    cgImage = croppedImage;
                    TSLog(LOG_NOTICE, "[TrollShot] 裁剪区域: (%.0f,%.0f) %.0fx%.0f -> 最终: %zux%zu",
                           clampedRect.origin.x, clampedRect.origin.y,
                           clampedRect.size.width, clampedRect.size.height,
                           CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
                }
            } else {
                TSLog(LOG_ERR, "[TrollShot] 裁剪区域超出图像范围，跳过裁剪");
                hasCrop = NO;
            }
        }

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

    if (!jpegData && error) {
        *error = [NSError errorWithDomain:@"TrollShot" code:3 userInfo:@{NSLocalizedDescriptionKey : @"JPEG 编码失败"}];
    }
    return jpegData;
}

@end
