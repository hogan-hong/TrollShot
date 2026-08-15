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
#import <IOKit/IOReturn.h>
#import <unistd.h>
#import <string.h>
#import "TSLogger.h"

/* 调试模式才输出 syslog，避免非调试模式下产生大量系统日志
 * 注意：TSLog 只写 syslog（系统日志），ScreenCapturer 关键诊断同时手动写 TSLogger（TrollShot.log） */
#define TSLog(priority, fmt, ...) do { \
    if ([[TSLogger sharedLogger] debugEnabled]) \
        syslog(priority, fmt, ##__VA_ARGS__); \
} while(0)

/* framebuffer 直读与 screendump 对齐：不加锁、不补偿、禁用色彩管理（见 README） */

/* 诊断全局变量 */
size_t g_lastOrigWidth = 0;
size_t g_lastOrigHeight = 0;
size_t g_lastFinalWidth = 0;
size_t g_lastFinalHeight = 0;
BOOL g_lastRotated = NO;
BOOL g_isJailbreakMode = NO;
BOOL g_useFramebuffer = NO;
BOOL g_needsMirror = NO;  /* 越狱模式：是否需要 AirPlay 镜像维持 isCaptured */


#if !defined(TROLLSHOT_CA_ONLY)
/* 越狱环境下尝试提升为 root 权限
 * rootful 越狱（checkra1n/unc0ver）内核补丁允许 setuid(0)
 * IOMobileFramebuffer 直读需要 root 权限 */
static void TryEscalateToRoot(void) {
    if (getuid() == 0) return;
    if (setuid(0) == 0) {
        TSLog(LOG_NOTICE, "[TrollShot] setuid(0) 成功，已提升为 root");
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"setuid(0) 成功，uid=%d", getuid()]];
    } else {
        TSLog(LOG_ERR, "[TrollShot] setuid(0) 失败: %s (errno=%d)", strerror(errno), errno);
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"setuid(0) 失败: errno=%d (%s)，uid=%d", errno, strerror(errno), getuid()]];
    }
}
#endif /* !TROLLSHOT_CA_ONLY */

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
#if !defined(TROLLSHOT_FB_ONLY) && !defined(TROLLSHOT_CA_ONLY)
/* 专用构建（FLAVOR=deb/ipa）不需要运行时越狱检测，模式在编译期已固定 */
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
#endif /* !TROLLSHOT_FB_ONLY && !TROLLSHOT_CA_ONLY */

@interface ScreenCapturer (Private)
- (void)setupCARenderServer;
- (BOOL)setupFramebufferDirectRead;
@end

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
    /* 截图链路已直读 IOSurface 字节，不再使用 CIContext */
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

+ (BOOL)needsMirror {
    return g_needsMirror;
}

+ (BOOL)isMirrorActive {
    return [[UIScreen mainScreen] isCaptured];
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

    /* 复用 FBSOrientationObserver（不再每次截图 new 一个） */
    @try {
        mOrientationObserver = [[FBSOrientationObserver alloc] init];
    } @catch (NSException *e) {
        TSLog(LOG_ERR, "[TrollShot] FBSOrientationObserver 初始化失败: %s", [e.reason UTF8String]);
        mOrientationObserver = nil;
    }

#if defined(TROLLSHOT_FB_ONLY)
    /* deb 专用构建（FLAVOR=deb）：越狱设备 root daemon，强制 framebuffer 直读。
     * 不做越狱检测、不含 CARenderServer 降级路径，截图并发固定 1。
     * 原理：
     * 1. IOMobileFramebuffer 直读系统帧缓冲，2-3ms/张，完全绕过 mach IPC
     * 2. framebuffer 直读绕过 SpringBoard，游戏防截屏会触发（画面变灰）
     * 3. 解决方案：设备开启 AirPlay 屏幕镜像，UIScreen.isCaptured = YES
     *    AirPlay 镜像让系统感知到屏幕正在被录制，游戏正常渲染彩色画面
     * 4. UxPlay 服务器用 -vs 0 丢弃视频流，不占服务器资源
     *    设备端只编码 16x16@1fps，开销极低 */
    g_isJailbreakMode = YES;
    if (getuid() != 0) {
        TryEscalateToRoot();
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"权限提升: uid=%d", getuid()]];
    }
    mUseFramebuffer = [self setupFramebufferDirectRead];
    g_useFramebuffer = mUseFramebuffer;
    g_needsMirror = mUseFramebuffer;  /* framebuffer 模式需要 AirPlay 镜像 */

    if (mUseFramebuffer) {
        TSLog(LOG_NOTICE, "[TrollShot] deb 专用构建: framebuffer 直读（需 AirPlay 镜像）");
        [[TSLogger sharedLogger] log:@"截图模式：framebuffer 直读（deb 专用构建，单线程）"];
    } else {
        TSLog(LOG_ERR, "[TrollShot] framebuffer 初始化失败，deb 专用构建无降级路径");
        [[TSLogger sharedLogger] log:@"截图模式：framebuffer 初始化失败（deb 专用构建不含 CARenderServer 降级），截图不可用"];
    }
#elif defined(TROLLSHOT_CA_ONLY)
    /* ipa 专用构建（FLAVOR=ipa）：非越狱 TrollStore 设备，纯 CARenderServer，
     * 与 TrollVNC 相同的截屏路线，截图并发固定 4。 */
    g_isJailbreakMode = NO;
    [self setupCARenderServer];
    [[TSLogger sharedLogger] log:@"截图模式：CARenderServer（ipa 专用构建，4 线程）"];
#else
    g_isJailbreakMode = DetectJailbreak();
    TSLog(LOG_NOTICE, "[TrollShot] 越狱检测: g_isJailbreakMode=%d, uid=%d", g_isJailbreakMode, getuid());
    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"越狱检测: mode=%d, uid=%d", g_isJailbreakMode, getuid()]];

    if (g_isJailbreakMode) {
        /* 越狱模式：纯 framebuffer 直读
         *
         * 原理：
         * 1. IOMobileFramebuffer 直读系统帧缓冲，2-3ms/张，完全绕过 mach IPC
         * 2. framebuffer 直读绕过 SpringBoard，游戏防截屏会触发（画面变灰）
         * 3. 解决方案：设备开启 AirPlay 屏幕镜像，UIScreen.isCaptured = YES
         *    AirPlay 镜像让系统感知到屏幕正在被录制，游戏正常渲染彩色画面
         * 4. UxPlay 服务器用 -vs 0 丢弃视频流，不占服务器资源
         *    设备端只编码 16x16@1fps，开销极低
         *
         * 启动时检查 isCaptured 状态，未开启镜像则标记需要镜像
         * 截图时实时检查 isCaptured，镜像断开则返回错误 */
        if (getuid() != 0) {
            TryEscalateToRoot();
            [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"权限提升: uid=%d", getuid()]];
        }

        /* 检查 AirPlay 镜像状态 */
        BOOL mirrorActive = [[UIScreen mainScreen] isCaptured];
        TSLog(LOG_NOTICE, "[TrollShot] AirPlay 镜像状态: isCaptured=%d", mirrorActive);
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"AirPlay 镜像状态: isCaptured=%d", mirrorActive]];

        /* 尝试 framebuffer 直读 */
        mUseFramebuffer = [self setupFramebufferDirectRead];
        g_useFramebuffer = mUseFramebuffer;
        g_needsMirror = mUseFramebuffer;  /* framebuffer 模式需要 AirPlay 镜像 */

        if (mUseFramebuffer) {
            TSLog(LOG_NOTICE, "[TrollShot] 越狱模式: framebuffer 直读（需 AirPlay 镜像）");
            if (mirrorActive) {
                [[TSLogger sharedLogger] log:@"截图模式：越狱 framebuffer 直读（镜像已开启）"];
            } else {
                [[TSLogger sharedLogger] log:@"截图模式：越狱 framebuffer 直读（警告：AirPlay镜像未开启，截图将灰屏）"];
            }
        } else {
            /* framebuffer 失败，降级为 CARenderServer */
            TSLog(LOG_NOTICE, "[TrollShot] framebuffer 直读失败，降级为 CARenderServer");
            [[TSLogger sharedLogger] log:@"截图模式：越狱 framebuffer降级 CARenderServer"];
            [self setupCARenderServer];
        }
    } else {
        /* 非越狱模式：纯 CARenderServer（与 TrollVNC 相同） */
        [self setupCARenderServer];
        [[TSLogger sharedLogger] log:@"截图模式：非越狱 CARenderServer"];
    }
#endif

    return self;
}

/* ============================================================
 * 非越狱模式初始化：创建 IOSurface 和 accelerator
 * （原逻辑完全保留，不修改）
 * ============================================================ */
- (void)setupCARenderServer {
#if !defined(TROLLSHOT_FB_ONLY)
    /* deb 专用构建不编译 CARenderServer 路径 */
    CGSize screenSize = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    int width = (int)round(screenSize.width);
    int height = (int)round(screenSize.height);

    unsigned pixelFormat = 0x42475241; /* 'BGRA'（与 framebuffer 源一致，纯拷贝语义） */
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = bytesPerComponent * 4;
    int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * width);

    /* 注意：不设置 kIOSurfaceColorSpace 标签 -- screendump 的目标 surface 无此标签，
     * 额外的色彩空间标签会让后续 blit/封装环节引入非预期的色彩处理（实测 +33 加白） */
    mRenderProperties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(width),
        (__bridge NSString *)kIOSurfaceHeight : @(height),
        (__bridge NSString *)kIOSurfacePixelFormat : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bytesPerRow * height),
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
#endif /* !TROLLSHOT_FB_ONLY */
}

/* ============================================================
 * 越狱模式初始化：直接链接 IOMobileFramebuffer 私有 API
 * 参考 screendump (fix14) 的实现方式，直接链接 framework
 * 直接读取系统 framebuffer，完全绕过 mach IPC 链路
 * ============================================================ */
- (BOOL)setupFramebufferDirectRead {
#if defined(TROLLSHOT_CA_ONLY)
    /* ipa 专用构建不编译 framebuffer 直读路径 */
    return NO;
#else
    /* 直接调用 IOMobileFramebuffer 函数（编译时链接 framework，与 screendump 相同方式） */
    [[TSLogger sharedLogger] log:@"framebuffer: 直接链接 IOMobileFramebuffer.framework"];

    /* 获取主显示屏 framebuffer 连接 */
    IOReturn ret = IOMobileFramebufferGetMainDisplay(&mFramebuffer);
    if (ret != kIOReturnSuccess || !mFramebuffer) {
        TSLog(LOG_ERR, "[TrollShot] IOMobileFramebufferGetMainDisplay 失败: 0x%x", ret);
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"framebuffer: GetMainDisplay 失败 ret=0x%x (uid=%d)", ret, getuid()]];
        return NO;
    }
    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"framebuffer: GetMainDisplay 成功 mFramebuffer=%p", mFramebuffer]];

    /* 获取默认层（layer 0）的 IOSurface -- 这是系统实时更新的帧缓冲
     * 与 screendump (fix14) 完全相同的调用方式 */
    ret = IOMobileFramebufferGetLayerDefaultSurface(mFramebuffer, 0, &mFbSurface);
    if (ret != kIOReturnSuccess || !mFbSurface) {
        TSLog(LOG_ERR, "[TrollShot] GetLayerDefaultSurface 失败: 0x%x，尝试 CopyLayerDisplayedSurface", ret);
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"framebuffer: GetLayerDefaultSurface 失败 ret=0x%x，尝试 CopyLayerDisplayedSurface", ret]];

        /* 备选：CopyLayerDisplayedSurface */
        ret = IOMobileFramebufferCopyLayerDisplayedSurface(mFramebuffer, 0, &mFbSurface);
        if (ret == kIOReturnSuccess && mFbSurface) {
            [[TSLogger sharedLogger] log:@"framebuffer: CopyLayerDisplayedSurface 成功"];
        } else {
            TSLog(LOG_ERR, "[TrollShot] CopyLayerDisplayedSurface 也失败: 0x%x", ret);
            [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"framebuffer: CopyLayerDisplayedSurface 失败 ret=0x%x", ret]];
            [[TSLogger sharedLogger] log:@"framebuffer: 所有方案均失败，降级为 CARenderServer"];
            return NO;
        }
    } else {
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"framebuffer: GetLayerDefaultSurface 成功 mFbSurface=%p", mFbSurface]];
        OSType fbFormat = IOSurfaceGetPixelFormat(mFbSurface);
        TSLog(LOG_NOTICE, "[TrollShot] framebuffer surface 像素格式: 0x%x ('%c%c%c%c')", fbFormat,
              (fbFormat >> 24) & 0xFF, (fbFormat >> 16) & 0xFF, (fbFormat >> 8) & 0xFF, fbFormat & 0xFF);
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"framebuffer: 源 surface 像素格式=0x%x 尺寸=%zux%zu", fbFormat, IOSurfaceGetWidth(mFbSurface), IOSurfaceGetHeight(mFbSurface)]];
    }

/* 创建目标 surface 和 accelerator，用于从 framebuffer 拷贝帧数据 */
    CGSize screenSize = [[UIScreen mainScreen] _unjailedReferenceBoundsInPixels].size;
    int width = (int)round(screenSize.width);
    int height = (int)round(screenSize.height);

    unsigned pixelFormat = 0x42475241; /* 'BGRA'（与 framebuffer 源一致，纯拷贝语义） */
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = bytesPerComponent * 4;
    int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * width);

    /* 不设置 kIOSurfaceColorSpace（与 screendump 一致，避免 blit 引入色彩处理） */
    mRenderProperties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(width),
        (__bridge NSString *)kIOSurfaceHeight : @(height),
        (__bridge NSString *)kIOSurfacePixelFormat : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bytesPerRow * height),
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
#endif /* !TROLLSHOT_CA_ONLY */
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

#if !defined(TROLLSHOT_CA_ONLY)
    if (mUseFramebuffer) {
        /* ====================================================
         * 越狱模式：framebuffer 直读
         * 需要 AirPlay 镜像维持 isCaptured 状态，否则游戏防截屏触发灰屏
         * ==================================================== */

        /* 实时检查 AirPlay 镜像状态 */
        if (![[UIScreen mainScreen] isCaptured]) {
            TSLog(LOG_ERR, "[TrollShot] AirPlay 镜像未开启，framebuffer 截图将灰屏");
            if (error)
                *error = [NSError errorWithDomain:@"TrollShot" code:5 userInfo:@{
                    NSLocalizedDescriptionKey : @"AirPlay 屏幕镜像未开启，无法截图（越狱 framebuffer 模式需要镜像维持防截屏）"
                }];
            return nil;
        }

        /* 脏帧检测：IOSurfaceGetSeed 判断画面是否变化
         * 帧缓存：seed 未变且无旋转/裁剪需求时直接返回上次结果
         * 从 framebuffer surface 拷贝到目标 surface */
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
    } else
#endif
#if !defined(TROLLSHOT_FB_ONLY)
    {
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
#else
    {
        /* deb 专用构建：framebuffer 未初始化成功，无 CARenderServer 降级路径 */
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:6 userInfo:@{NSLocalizedDescriptionKey : @"framebuffer 未初始化，截图不可用（deb 专用构建）"}];
        return nil;
    }
#endif
    ;

    /* 从源 surface 拷贝到目标 surface（两种模式共用）
     * 与 screendump 对齐：不加锁。AirPlay 镜像开启后 fb 更新节奏稳定，
     * 实测无花屏；加锁与 CIColorMatrix 补偿反而引入了非线性色偏。 */
    IOReturn accelRet = IOSurfaceAcceleratorTransferSurface(mAccelerator, srcSurface, mScreenSurface, NULL, NULL, NULL, NULL);
    if (accelRet != kIOReturnSuccess) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:1 userInfo:@{NSLocalizedDescriptionKey : @"IOSurface 加速器转换失败"}];
        return nil;
    }

    /* 直接从 IOSurface 读字节构建 CGImage -- 与 screendump 推 VNC 字节完全同语义。
     * 不经 CVPixelBuffer/CIImage/CIContext：实测即使禁用 CIContext 色彩管理，
     * 该链路仍给画面带来均匀 +33/255 的加白偏移；直读字节零处理。 */
    size_t surfW = IOSurfaceGetWidth(mScreenSurface);
    size_t surfH = IOSurfaceGetHeight(mScreenSurface);
    size_t rowBytes = IOSurfaceGetBytesPerRow(mScreenSurface);
    void *base = IOSurfaceGetBaseAddress(mScreenSurface);
    if (!base || !rowBytes) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:2 userInfo:@{NSLocalizedDescriptionKey : @"IOSurface 字节指针获取失败"}];
        return nil;
    }
    NSData *pixelData = [NSData dataWithBytes:base length:rowBytes * surfH];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixelData);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    /* 'BGRA' 内存布局：小端 32 位 + Alpha 首位（内存序 B,G,R,A），alpha 恒 255，预乘无差 */
    CGImageRef cgImage = CGImageCreate(surfW, surfH, 8, 32, rowBytes, cs,
                                       kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
                                       provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    if (!cgImage) {
        if (error)
            *error = [NSError errorWithDomain:@"TrollShot" code:2 userInfo:@{NSLocalizedDescriptionKey : @"CGImageCreate 失败"}];
        return nil;
    }

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


- (void)dealloc {
}

@end