/*
 This file is part of TrollShot, derived from TrollVNC.
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 诊断用：记录最近一次截图的原始尺寸和是否旋转 */
extern size_t g_lastOrigWidth;
extern size_t g_lastOrigHeight;
extern size_t g_lastFinalWidth;
extern size_t g_lastFinalHeight;
extern BOOL g_lastRotated;

@interface ScreenCapturer : NSObject

+ (instancetype)sharedCapturer;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/** 截取当前屏幕并编码为 JPEG。quality 范围为 0..1。 */
- (nullable NSData *)captureJPEGWithQuality:(CGFloat)quality error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
