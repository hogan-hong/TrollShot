/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/** 在指定端口启动一个简单的 HTTP 服务器，调用线程会被阻塞。 */
void StartScreenshotServer(uint16_t port);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
