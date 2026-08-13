/*
 * TrollShot IOMobileFramebuffer SPI 声明
 * 参考 screendump (fix14) 项目，越狱环境下直接读取 framebuffer
 * 使用 dlsym 动态加载，非越狱环境不链接此框架
 */

#pragma once

#include "IOKitSPI.h"
#include "IOSurfaceSPI.h"
#include <CoreGraphics/CGGeometry.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

/* 获取主显示屏的 framebuffer 连接（越狱 root 权限可用） */
typedef IOReturn (*IOMobileFramebufferGetMainDisplayFunc)(IOMobileFramebufferRef *pointer);
/* 获取指定层的默认 IOSurface（系统实时更新的帧缓冲） */
typedef IOReturn (*IOMobileFramebufferGetLayerDefaultSurfaceFunc)(IOMobileFramebufferRef pointer, int layer, IOSurfaceRef *buffer);
/* 获取指定层当前显示的 IOSurface（备用方案） */
typedef IOReturn (*IOMobileFramebufferCopyLayerDisplayedSurfaceFunc)(IOMobileFramebufferRef pointer, int layer, IOSurfaceRef *buffer);
/* 获取显示尺寸 */
typedef void (*IOMobileFramebufferGetDisplaySizeFunc)(IOMobileFramebufferRef connect, CGSize *size);

#ifdef __cplusplus
}
#endif
