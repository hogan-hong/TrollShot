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

/* 诊断用：当前截图模式（越狱=framebuffer直读 / 非越狱=CARenderServer渲染） */
extern BOOL g_isJailbreakMode;
extern BOOL g_useFramebuffer;  /* 实际是否使用 framebuffer 直读（越狱但framebuffer失败时为NO） */

@interface ScreenCapturer : NSObject

+ (instancetype)sharedCapturer;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/** 截取当前屏幕并编码为 JPEG。
 *  quality 范围为 0..1。rotate 为 YES 时强制旋转90度。
 *  cropRect 非空时只裁剪指定区域（基于旋转后的最终图像坐标）。
 *  cropRect 传 CGRectZero 表示不裁剪，返回全屏。
 *  越狱环境下使用 IOMobileFramebuffer 直读（高效，不经过 mach IPC）；
 *  非越狱环境下使用 CARenderServerRenderDisplay（TrollStore 兼容）。 */
- (nullable NSData *)captureJPEGWithQuality:(CGFloat)quality rotate:(BOOL)rotate cropRect:(CGRect)cropRect error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
