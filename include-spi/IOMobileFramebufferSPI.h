/*
 * TrollShot IOMobileFramebuffer SPI 声明
 * 参考 screendump (fix14) 项目，越狱环境下直接读取 framebuffer
 * 直接链接 IOMobileFramebuffer.framework（与 screendump 相同方式）
 */

#pragma once

#include "IOKitSPI.h"
#include "IOSurfaceSPI.h"
#include <CoreGraphics/CGGeometry.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

/* 直接声明函数（编译时链接 IOMobileFramebuffer.framework） */
IOReturn IOMobileFramebufferGetMainDisplay(IOMobileFramebufferRef *pointer);
IOReturn IOMobileFramebufferGetLayerDefaultSurface(IOMobileFramebufferRef connect, int layer, IOSurfaceRef *buffer);
IOReturn IOMobileFramebufferCopyLayerDisplayedSurface(IOMobileFramebufferRef connect, int layer, IOSurfaceRef *buffer);
void IOMobileFramebufferGetDisplaySize(IOMobileFramebufferRef connect, CGSize *size);

#ifdef __cplusplus
}
#endif
