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

#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <netinet/in.h>
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "HTTPScreenshotServer.h"

static volatile BOOL gKeepRunning = YES;

static void onSignal(int sig) {
    gKeepRunning = NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGTERM, onSignal);
        signal(SIGINT, onSignal);

        uint16_t port = 8080;
        if (argc >= 3 && strcmp(argv[1], "--port") == 0) {
            port = (uint16_t)atoi(argv[2]);
        }

        NSLog(@"[TrollShot] trollshotd 启动，监听端口 %u", port);

        /* 后台 HTTP 服务器在这里阻塞运行 */
        StartScreenshotServer(port);

        NSLog(@"[TrollShot] trollshotd 退出");
    }
    return 0;
}
