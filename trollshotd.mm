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
#import <pthread.h>
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "HTTPScreenshotServer.h"
#import "TSLogger.h"

static volatile BOOL gKeepRunning = YES;
static uint16_t gPort = 8080;
static BOOL gDebug = NO;

static void onSignal(int sig) {
    gKeepRunning = NO;
    /* 收到终止信号后停止主 runloop，让进程干净退出 */
    CFRunLoopStop(CFRunLoopGetMain());
}

/* HTTP 服务独立线程入口，不依赖 GCD */
static void *ServerThreadEntry(void *arg) {
    NSLog(@"[TrollShot] HTTP 服务线程入口");
    StartScreenshotServer(gPort);
    NSLog(@"[TrollShot] HTTP 服务线程退出（不应发生）");
    return NULL;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGTERM, onSignal);
        signal(SIGINT, onSignal);
        signal(SIGHUP, SIG_IGN);

        uint16_t port = 8080;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
                port = (uint16_t)atoi(argv[++i]);
            } else if (strcmp(argv[i], "--debug") == 0) {
                gDebug = YES;
            }
        }
        gPort = port;

        /* 调试模式开启时才写日志 */
        [TSLogger sharedLogger].debugEnabled = gDebug;

        if (gDebug) {
            NSLog(@"[TrollShot] trollshotd 启动（调试模式），监听端口 %u", port);
        }

        /* HTTP 服务在独立 pthread 中运行，避免阻塞主 runloop，同时不依赖 GCD */
        pthread_t serverThread;
        int ptRet = pthread_create(&serverThread, NULL, ServerThreadEntry, NULL);
        NSLog(@"[TrollShot] pthread_create 返回 %d", ptRet);
        if (ptRet == 0) {
            pthread_detach(serverThread);
        }

        /* 主线程保持 runloop 运转，供 ScreenCapturer 的 IOSurfaceAccelerator RunLoop Source 使用。
         * CFRunLoopRun() 在 runloop 上没有任何 source/timer 时会立即返回导致进程退出，
         * 所以先添加一个空的 NSMachPort 保持 runloop alive。 */
        [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        NSLog(@"[TrollShot] 进入 CFRunLoopRun()");
        CFRunLoopRun();
        NSLog(@"[TrollShot] CFRunLoopRun 返回（不应发生）");

        if (gDebug) {
            NSLog(@"[TrollShot] trollshotd 退出");
        }
    }
    return 0;
}
