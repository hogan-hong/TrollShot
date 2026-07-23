/*
 * TrollShot 最小化 IOSurface SPI 声明
 * 基于 TrollVNC 的 IOSurfaceSPI.h 和逆向工程签名
 */

#pragma once

#include <IOSurface/IOSurfaceTypes.h>
#include <CoreFoundation/CFBase.h>
#include "IOKitSPI.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOSurface *IOSurfaceRef;
typedef struct __IOSurfaceAccelerator *IOSurfaceAcceleratorRef;

extern const CFStringRef kIOSurfaceAllocSize;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfaceCacheMode;
extern const CFStringRef kIOSurfaceColorSpace;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceElementWidth;
extern const CFStringRef kIOSurfaceElementHeight;

size_t IOSurfaceAlignProperty(CFStringRef property, size_t value);
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);

/* IOSurfaceAccelerator */
extern const CFStringRef kIOSurfaceAcceleratorUseStraightAlpha;
IOSurfaceAcceleratorRef IOSurfaceAcceleratorCreate(CFAllocatorRef allocator, id options, IOSurfaceAcceleratorRef *outAccelerator);
CFRunLoopSourceRef IOSurfaceAcceleratorGetRunLoopSource(IOSurfaceAcceleratorRef accelerator);
IOReturn IOSurfaceAcceleratorTransferSurface(IOSurfaceAcceleratorRef accelerator, IOSurfaceRef source, IOSurfaceRef dest, CFDictionaryRef dict1, CFDictionaryRef dict2, CFDictionaryRef dict3, void **outInfo);

#ifdef __cplusplus
}
#endif
