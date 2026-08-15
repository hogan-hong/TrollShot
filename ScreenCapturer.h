/*
 This file is part of TrollShot, derived from TrollVNC.
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/* 诊断用：记录最近一次截图的原始尺寸和是否旋转 */
extern size_t g_lastOrigWidth;
extern size_t g_lastOrigHeight;
extern size_t g_lastFinalWidth;
extern size_t g_lastFinalHeight;
extern BOOL g_lastRotated;
/* 诊断用：format=raw 最近一次返回的 surface 字节布局（BGRA） */
extern size_t g_lastRawWidth;
extern size_t g_lastRawHeight;
extern size_t g_lastRowBytes;

/* 诊断用：当前截图模式（越狱=framebuffer直读 / 非越狱=CARenderServer渲染） */
extern BOOL g_isJailbreakMode;
extern BOOL g_useFramebuffer;  /* 实际是否使用 framebuffer 直读（越狱但framebuffer失败时为NO） */
extern BOOL g_needsMirror;     /* 越狱 framebuffer 模式需要 AirPlay 镜像维持 isCaptured */

@interface ScreenCapturer : NSObject

+ (instancetype)sharedCapturer;

/** 越狱模式是否需要 AirPlay 镜像（framebuffer 直读依赖 isCaptured 状态） */
+ (BOOL)needsMirror;

/** 当前 AirPlay 屏幕镜像是否活跃（UIScreen.isCaptured） */
+ (BOOL)isMirrorActive;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/** 截取当前屏幕并编码为 JPEG。
 *  quality 范围为 0..1。rotate 为 YES 时强制旋转90度。
 *  cropRect 非空时只裁剪指定区域（基于旋转后的最终图像坐标）。
 *  cropRect 传 CGRectZero 表示不裁剪，返回全屏。
 *  越狱环境下使用 IOMobileFramebuffer 直读（高效，不经过 mach IPC）；
 *  需要先开启 AirPlay 屏幕镜像维持 UIScreen.isCaptured 状态，否则游戏防截屏会触发。
 *  非越狱环境下使用 CARenderServerRenderDisplay（TrollStore 兼容）。 */
- (nullable NSData *)captureJPEGWithQuality:(CGFloat)quality rotate:(BOOL)rotate cropRect:(CGRect)cropRect error:(NSError **)error;

/** 扩展输出格式（诊断用）：jpeg（默认，同上）/ png（无损编码）/
 *  raw（IOSurface transfer 后的原始 BGRA 字节，跳过 CGImage 封装与编码，忽略 rotate/crop）。
 *  raw 用于排查色彩偏移发生在 transfer、CGImage 封装还是编码环节。 */
- (nullable NSData *)captureWithFormat:(NSString *)format quality:(CGFloat)quality rotate:(BOOL)rotate cropRect:(CGRect)cropRect error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
