/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Start a simple HTTP server on the given port. Blocks the calling thread. */
void StartScreenshotServer(uint16_t port);

NS_ASSUME_NONNULL_END
