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
#import "IOMobileFramebufferSPI.h"
#import "UIScreen+Private.h"
#import "FBSOrientationObserver.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <syslog.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import "TSLogger.h"

/* 调试模式才输出 syslog，避免非调试模式下产生大量系统日志
 * 注意：TSLog 只写 syslog（系统日志），ScreenCapturer 关键诊断同时手动写 TSLogger（TrollShot.log） */
#define TSLog(priority, fmt, ...) do { \
    if ([[TSLogger sharedLogger] debugEnabled]) \
        syslog(priority, fmt, ##__VA_ARGS__); \
} while(0)

/* 诊断全局变量 */
size_t g_lastOrigWidth = 0;
size_t g_lastOrigHeight = 0;
size_t g_lastFinalWidth = 0;
size_t g_lastFinalHeight = 0;
BOOL g_lastRotated = NO;
BOOL g_isJailbreakMode = NO;
BOOL g_useFramebuffer = NO;

/* 越狱环境下尝试提升为 root 权限
 * rootful 越狱（checkra1n/unc0ver）内核补丁允许 setuid(0)
 * IOMobileFramebuffer 直读需要 root 权限 */
static void TryEscalateToRoot(void) {
    if (getuid() == 0) return;
    if (setuid(0) == 0) {
        TSLog(LOG_NOTICE, "[TrollShot] setuid(0) 成功，已提升为 root");
    } else {
        TSLog(LOG_ERR, "[TrollShot] setuid(0) 失败: %s (errno=%d)", strerror(errno), errno);
    }
}

#ifdef __cplusplus
extern "C" {
#endif

CFIndex CARenderServerGetDirtyFrameCount(void *);
/* 将主显示屏内容渲染到 IOSurface（非越狱模式使用） */
void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

#ifdef __cplusplus
}
#endif

/* ============================================================
 * 越狱检测：daemon 以 root 运行 = 越狱模式
 * 非越狱（TrollStore）以 mobile 用户运行
 * ============================================================ */
static BOOL DetectJailbreak(void) {
    static BOOL result = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        /* daemon 由 launchd 以 root 启动，TrollStore app 以 mobile 运行 */
        if (getuid() == 0) {
            result = YES;
            return;
        }
        /* rootless 越狱标记（Dopamine/palera1n 等） */
        if (access("/var/jb", F_OK) == 0 || access("/.bootstrapped", F_OK) == 0 ||
            access("/var/binpack", F_OK) == 0) {
            result = YES;
            return;
        }
        /* rootful 越狱标记（checkra1n/unc0ver 等，以 mobile 运行但设备已越狱） */
        if (access("/Library/MobileSubstrate/MobileSubstrate.dylib", F_OK) == 0 ||
            access("/usr/lib/substitute-loader.dylib", F_OK) == 0 ||
            access("/usr/lib/libsubstitute.0.dylib", F_OK) == 0 ||
            access("/Applications/Cydia.app", F_OK) == 0 ||
            access("/Applications/Sileo.app", F_OK) == 0 ||
            access("/private/var/lib/apt", F_OK) == 0 ||
            access("/usr/sbin/sshd", F_OK) == 0) {
            result = YES;
            return;
        }
        /* Substitute 注入检测（dlsym 检查 MSHookFunction 符号） */
        if (dlsym(RTLD_DEFAULT, "MSHookFunction") != NULL) {
            result = YES;
            return;
        }
    });
    return result;
}

@implementation ScreenCapturer {
    /* 共用：渲染属性和目标 surface */
    NSDictionary *mRenderProperties;
    IOSurfaceRef mScreenSurface;      /* 目标 surface（两种模式都用到） */
    IOSurfaceRef mSrcSurface;         /* 源 surface（仅非越狱 CARenderServer 模式） */
    IOSurfaceAcceleratorRef mAccelerator;

    /* 越狱模式：framebuffer 直读 */
    BOOL mUseFramebuffer;
    IOMobileFramebufferRef mFramebuffer;
    IOSurfaceRef mFbSurface;          /* 系统 framebuffer 的 IOSurface */
    uint32_t mLastSeed;               /* 上次帧的 seed（脏帧检测） */

    /* 复用对象（避免每次截图重新创建，减少内存分配和 GC 压力） */
    CIContext *mCIContext;            /* 复用 CIContext */
    FBSOrientationObserver *mOrientationObserver;  /* 复用方向观察者 */

    /* 帧缓存（seed 未变或时间间隔短时直接返回上次结果，减少重复编码） */
    NSData *mCachedJPEG;
    BOOL mHasCachedFrame;
    NSTimeInterval mLastCaptureTime;  /* 上次截图时间（CARenderServer 模式时间缓存） */

    /* 线程安全锁 */
    NSLock *mLock;
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

    mLock = [[NSLock alloc] init];
    mUseFramebuffer = NO;
    mHasCachedFrame = NO;
    mLastSeed = 0;
    mLastCaptureTime = 0;

    /* 复用 CIContext（不再每次截图 new 一个） */
    mCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @NO}];

    /* 复用 FBSOrientationObserver（不再每次截图 new 一个） */
    @try {
        mOrientationObserver = [[FBSOrientationObserver alloc] init];
    } @catch (NSException *e) {
        TSLog(LOG_ERR, "[TrollShot] FBSOrientationObserver 初始化失败: %s", [e.reason UTF8String]);
        mOrientationObserver = nil;
    }

    g_isJailbreakMode = DetectJailbreak();
    TSLog(LOG_NOTICE, "[TrollShot] 越狱检测: g_isJailbreakMode=%d, uid=%d", g_isJailbreakMode, getuid());
    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"越狱检测: mode=%d, uid=%d", g_isJailbreakMode, getuid()]];

    if (g_isJailbreakMode) {
        /* 越狱模式：尝试提升为 root（framebuffer 直读需要 root 权限）
         * rootful 越狱（checkra1n/unc0ver）内核补丁允许 setuid(0) */
        if (getuid() != 0) {
            TryEscalateToRoot();
            [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"权限提升: uid=%d", getuid()]];
        }

        /* 尝试 framebuffer 直读 */
        mUseFramebuffer = [self setupFramebufferDirectRead];
        g_useFramebuffer = mUseFramebuffer;

        if (mUseFramebuffer) {
            TSLog(LOG_NOTICE, "[TrollShot] 越狱模式: framebuffer 直读初始化成功");
            [[TSLogger sharedLogger] log:@"截图模式：越狱 IOMobileFramebuffer 直读"];
        } else {
            /* framebuffer 失败，降级为 CARenderServer，但保持越狱模式标记（串行执行）
             * 越狱环境即使降级也必须串行，避免 Substitute hook 并发 mach IPC 开销 */
            TSLog(LOG_NOTICE, "[TrollShot] framebuffer 直读失败，降级为 CARenderServer（串行）");
            [[TSLogger sharedLogger] log:@"截图模式：越狱但framebuffer降级CARenderServer（串行）"];
            /* 不重置 g_isJailbreakMode，保持串行执行 */
        }
    }

    if (!mUseFramebuffer) {
        /* 非越狱路径或越狱降级路径：创建 IOSurface + accelerator */
        [self setupCARenderServer];
        if (!g_isJailbreakMode) {
            [[TSLogger sharedLogger] log:@"截图模式：非越狱 CARenderServer"];
        }
    }

    return self;
}

/* ============================================================
 * 非越狱模式初始化：创建 IOSurface 和 accelerator
 * （原逻辑完全保留，不修改）
 * ============================================================ */
- (void)setupCARenderServer {
    CGSize screenSize = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    int width = (int)round(screenSize.width);
    int height = (int)round(screenSize.height);

    unsigned pixelFormat = 0x42475241; /* 'ARGB' */
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
    mSrcSurface = IOSurfaceCreate((__bridge CFDictionaryRef)mRenderProperties);

    IOReturn accelCreateRet = IOSurfaceAcceleratorCreate(kCFAllocatorDefault, NULL, &mAccelerator);
    if (accelCreateRet == kIOReturnSuccess && mAccelerator) {
        CFRunLoopSourceRef runLoopSource = IOSurfaceAcceleratorGetRunLoopSource(mAccelerator);
        if (runLoopSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
        }
    }
}

/* ============================================================
 * 越狱模式初始化：通过 dlsym 加载 IOMobileFramebuffer 私有 API
 * 参考 screendump (fix14) 的 IOMobileFramebufferGetLayerDefaultSurface 方案
 * 直接读取系统 framebuffer，完全绕过 mach IPC 链路
 * ============================================================ */
- (BOOL)setupFramebufferDirectRead {
    /* dlopen IOKit 私有框架 */
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) {
        TSLog(LOG_ERR, "[TrollShot] dlopen IOKit 失败: %s", dlerror());
        return NO;
    }

    /* dlsym 加载 IOMobileFramebuffer 函数 */
    IOMobileFramebufferGetMainDisplayFunc getMainDisplay =
        (IOMobileFramebufferGetMainDisplayFunc)dlsym(iokit, "IOMobileFramebufferGetMainDisplay");
    IOMobileFramebufferGetLayerDefaultSurfaceFunc getLayerSurface =
        (IOMobileFramebufferGetLayerDefaultSurfaceFunc)dlsym(iokit, "IOMobileFramebufferGetLayerDefaultSurface");

    if (!getMainDisplay || !getLayerSurface) {
        TSLog(LOG_ERR, "[TrollShot] dlsym IOMobileFramebuffer 函数未找到");
        return NO;
    }

    /* 获取主显示屏 framebuffer 连接 */
    IOReturn ret = getMainDisplay(&mFramebuffer);
    if (ret != kIOReturnSuccess || !mFramebuffer) {
        TSLog(LOG_ERR, "[TrollShot] IOMobileFramebufferGetMainDisplay 失败: 0x%x", ret);
        return NO;
    }

    /* 获取默认层（layer 0）的 IOSurface —— 这是系统实时更新的帧缓冲 */
    ret = getLayerSurface(mFramebuffer, 0, &mFbSurface);
    if (ret != kIOReturnSuccess || !mFbSurface) {
        TSLog(LOG_ERR, "[TrollShot] IOMobileFramebufferGetLayerDefaultSurface 失败: 0x%x", ret);
        return NO;
    }

    /* 创建目标 surface 和 accelerator，用于从 framebuffer 拷贝帧数据 */
    CGSize screenSize = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    int width = (int)round(screenSize.width);
    int height = (int)round(screenSize.height);

    unsigned pixelFormat = 0x42475241; /* 'ARGB' */
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

    IOReturn accelCreateRet = IOSurfaceAcceleratorCreate(kCFAllocatorDefault, NULL, &mAccelerator);
    if (accelCreateRet == kIOReturnSuccess && mAccelerator) {
        CFRunLoopSourceRef runLoopSource = IOSurfaceAcceleratorGetRunLoopSource(mAccelerator);
        if (runLoopSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
        }
    }

    /* 初始化 seed */
    mLastSeed = IOSurfaceGetSeed(mFbSurface);

    TSLog(LOG_NOTICE, "[TrollShot] framebuffer 直读: surface=%p, seed=%u, size=%dx%d",
          mFbSurface, mLastSeed, width, height);

    return YES;
}

/* ============================================================
 * 截图入口：根据模式选择截图路径
 * ============================================================ */
- (NSData *)captureJPEGWithQuality:(CGFloat)quality rotate:(BOOL)rotate cropRect:(CGRect)cropRect error:(NSError **)error {
    if (quality < 0.0)
        quality = 0.0;
    if (quality > 1.0)
        quality = 1.0;

    /* 线程安全：同一时间只有一个截图操作 */
    [mLock lock];
    NSData *result = [self captureInternal:quality rotate:rotate cropRect:cropRect error:error];
    [mLock unlock];
    return result;
}

/* ============================================================
 * 内部截图实现
 * ============================================================ */
- (NSData *)captureInternal:(CGFloat)quality rotate:(BOOL)rotate cropRect:(CGRect)cropRect error:(NSError **)error {
    if (!mScreenSurface || !mAccelerator) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:4 userInfo:@{NSLocalizedDescriptionKey : @"IOSurface 加速器未初始化"}];
        return nil;
    }

    IOSurfaceRef srcSurface = NULL;

    if (mUseFramebuffer) {
        /* ====================================================
         * 越狱模式：framebuffer 直读
         * 1. 脏帧检测：IOSurfaceGetSeed 判断画面是否变化
         * 2. 帧缓存：seed 未变且无旋转/裁剪需求时直接返回上次结果
         * 3. 从 framebuffer surface 拷贝到目标 surface
         * ==================================================== */
        uint32_t currentSeed = IOSurfaceGetSeed(mFbSurface);
        BOOL frameChanged = (currentSeed != mLastSeed);
        mLastSeed = currentSeed;

        if (!frameChanged && mHasCachedFrame && !rotate && CGRectIsEmpty(cropRect)) {
            /* 帧没变，且不需要旋转/裁剪，直接返回缓存 */
            TSLog(LOG_NOTICE, "[TrollShot] 帧未变化(seed=%u)，返回缓存 JPEG", currentSeed);
            return mCachedJPEG;
        }

        srcSurface = mFbSurface;
        TSLog(LOG_NOTICE, "[TrollShot] 越狱模式: framebuffer 直读, seed=%u, changed=%d", currentSeed, frameChanged);
    } else {
        /* ====================================================
         * CARenderServer 模式（非越狱 或 越狱降级）
         * 时间缓存：300ms 内重复请求直接返回上次结果，减少 mach IPC 开销
         * ==================================================== */
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (mHasCachedFrame && !rotate && CGRectIsEmpty(cropRect) && (now - mLastCaptureTime) < 0.3) {
            TSLog(LOG_NOTICE, "[TrollShot] CARenderServer 时间缓存命中（%.0fms），返回缓存", (now - mLastCaptureTime) * 1000);
            return mCachedJPEG;
        }

        if (!mSrcSurface) {
            if (error)
                *error = [NSError errorWithDomain:@"TrollShot" code:4 userInfo:@{NSLocalizedDescriptionKey : @"源 IOSurface 未初始化"}];
            return nil;
        }

        CARenderServerRenderDisplay(0, CFSTR("LCD"), mSrcSurface, 0, 0);
        srcSurface = mSrcSurface;
        mLastCaptureTime = now;
    }

    /* 从源 surface 拷贝到目标 surface（两种模式共用） */
    IOReturn accelRet = IOSurfaceAcceleratorTransferSurface(mAccelerator, srcSurface, mScreenSurface, NULL, NULL, NULL, NULL);
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

    /* 用复用的 CIContext 将 ARGB 缓冲区转为 CGImage */
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImageRef cgImage = [mCIContext createCGImage:ciImage fromRect:[ciImage extent]];

    CVPixelBufferRelease(pixelBuffer);

    /*
     * 方向校正（CGContext 手动旋转）：
     * 使用复用的 FBSOrientationObserver 获取当前设备方向。
     * rotate=YES 时强制旋转（手动覆盖，如 ?rotate=1）；
     * rotate=NO 时自动检测：横屏(Landscape)则旋转，竖屏(Portrait)则不旋转。
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

        /* 自动检测当前设备方向（复用 mOrientationObserver） */
        BOOL shouldRotate = rotate;
        if (!shouldRotate && mOrientationObserver) {
            @try {
                UIInterfaceOrientation orientation = [mOrientationObserver activeInterfaceOrientation];
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

    /* 缓存帧结果（仅在无旋转无裁剪时缓存，两种模式共用） */
    if (jpegData && !rotate && CGRectIsEmpty(cropRect)) {
        mCachedJPEG = jpegData;
        mHasCachedFrame = YES;
    }

    return jpegData;
}

@end
