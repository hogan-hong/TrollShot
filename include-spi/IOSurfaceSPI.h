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
extern const CFStringRef kIOSurfacePlaneWidth;
extern const CFStringRef kIOSurfacePlaneHeight;
extern const CFStringRef kIOSurfacePlaneBytesPerRow;
extern const CFStringRef kIOSurfacePlaneOffset;
extern const CFStringRef kIOSurfacePlaneSize;
extern const CFStringRef kIOSurfacePlaneInfo;
extern const CFStringRef kIOSurfaceMemoryRegion;

size_t IOSurfaceAlignProperty(CFStringRef property, size_t value);
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
mach_port_t IOSurfaceCreateMachPort(IOSurfaceRef buffer);
size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
size_t IOSurfaceGetPropertyMaximum(CFStringRef property);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
OSType IOSurfaceGetPixelFormat(IOSurfaceRef buffer);
void IOSurfaceIncrementUseCount(IOSurfaceRef buffer);
Boolean IOSurfaceIsInUse(IOSurfaceRef buffer);
IOReturn IOSurfaceLock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
IOSurfaceRef IOSurfaceLookupFromMachPort(mach_port_t);
IOReturn IOSurfaceUnlock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
size_t IOSurfaceGetWidthOfPlane(IOSurfaceRef buffer, size_t planeIndex);
size_t IOSurfaceGetHeightOfPlane(IOSurfaceRef buffer, size_t planeIndex);
IOReturn IOSurfaceSetPurgeable(IOSurfaceRef buffer, uint32_t newState, uint32_t *oldState);

/* IOSurfaceAccelerator */
extern const CFStringRef kIOSurfaceAcceleratorUnwireSurfaceKey;

IOReturn IOSurfaceAcceleratorCreate(CFAllocatorRef allocator, CFDictionaryRef properties, IOSurfaceAcceleratorRef *outAccelerator);
CFRunLoopSourceRef IOSurfaceAcceleratorGetRunLoopSource(IOSurfaceAcceleratorRef accelerator);

typedef void (*IOSurfaceAcceleratorCompletionCallback)(void *completionRefCon, IOReturn status, void *completionRefCon2);

typedef struct IOSurfaceAcceleratorCompletion {
    IOSurfaceAcceleratorCompletionCallback completionCallback;
    void *completionRefCon;
    void *completionRefCon2;
} IOSurfaceAcceleratorCompletion;

IOReturn IOSurfaceAcceleratorTransferSurface(IOSurfaceAcceleratorRef accelerator, IOSurfaceRef sourceBuffer, IOSurfaceRef destinationBuffer, void *a, void *b, void *c, void *d);
IOReturn IOSurfaceAcceleratorTransformSurface(IOSurfaceAcceleratorRef accelerator, IOSurfaceRef sourceBuffer, IOSurfaceRef destinationBuffer, CFDictionaryRef options, void *cropRectangles, IOSurfaceAcceleratorCompletion *completion, void *swapInfo, uint32_t *commandID);

#ifdef __cplusplus
}
#endif
