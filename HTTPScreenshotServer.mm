/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "HTTPScreenshotServer.h"
#import "ScreenCapturer.h"
#import "TSLogger.h"

#import <CoreGraphics/CoreGraphics.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <pthread.h>
#import <string.h>
#import <stdio.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <unistd.h>
#import <spawn.h>
#import <stdlib.h>

/* 最大并发截图请求数，避免高并发时创建过多线程导致系统拒绝连接 */
static const int kMaxConcurrentRequests = 4;
static dispatch_semaphore_t gConcurrencySem;

/* HandleClientConnection 在下方定义，线程入口需要前向声明 */
static void HandleClientConnection(int client);

/* 客户端连接参数 */
struct ClientContext {
    int clientSocket;
};

/* 客户端处理线程入口 */
static void *HandleClientThread(void *arg) {
    @autoreleasepool {
        struct ClientContext *ctx = (struct ClientContext *)arg;
        int client = ctx->clientSocket;
        free(ctx);
        @try {
            HandleClientConnection(client);
        } @finally {
            dispatch_semaphore_signal(gConcurrencySem);
        }
        return NULL;
    }
}

/* 
 * 直接在当前 pthread 线程截图，不使用 dispatch_sync(dispatch_get_main_queue())。
 * 在 daemon 进程中 GCD 主队列可能与主线程 RunLoop 关联异常，
 * 导致 HTTP 请求一直等待而转圈。ScreenCapturer 初始化时已将
 * IOSurfaceAccelerator 的 RunLoop Source 挂到主 RunLoop，后续截图可在任意线程同步调用。
 */
static void SendResponse(int client, int statusCode, NSString *contentType, NSData *body) {
    NSString *statusLine = nil;
    switch (statusCode) {
        case 200:
            statusLine = @"HTTP/1.1 200 OK";
            break;
        case 404:
            statusLine = @"HTTP/1.1 404 Not Found";
            break;
        default:
            statusLine = @"HTTP/1.1 500 Internal Server Error";
            break;
    }

    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"%@\r\n", statusLine];
    if (contentType.length > 0) {
        [header appendFormat:@"Content-Type: %@\r\n", contentType];
    }
    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [header appendString:@"Connection: close\r\n"];
    [header appendString:@"Cache-Control: no-store\r\n"];
    [header appendString:@"\r\n"];

    const char *headerBytes = header.UTF8String;
    send(client, headerBytes, strlen(headerBytes), 0);
    if (body.length > 0) {
        send(client, body.bytes, body.length, 0);
    }
}

/*
 * daemon 自行关闭：以 root 权限卸载 launchd plist，然后退出进程。
 * 这样即使 KeepAlive=true，launchd 也不会再重启 daemon。
 * 越狱环境下 App（mobile 用户）无权 kill root 进程或 unload 系统 plist，
 * 所以通过 HTTP /shutdown 请求让 daemon 自己来完成。
 */
static void *ShutdownThreadEntry(void *arg) {
    @autoreleasepool {
        [[TSLogger sharedLogger] log:@"收到关闭请求，开始卸载 launchd..."];

        /* 先 bootout（iOS 14+ 新语法） */
        pid_t bootoutPid = 0;
        char *bootoutArgs[] = {(char *)"launchctl", (char *)"bootout", (char *)"system/com.hogan.trollshot", NULL};
        if (posix_spawn(&bootoutPid, "/bin/launchctl", NULL, NULL, bootoutArgs, NULL) == 0) {
            int st = 0;
            waitpid(bootoutPid, &st, 0);
        }

        /* 再 unload（旧语法兜底，不加 -w 以免永久禁用导致无法重启） */
        pid_t unloadPid = 0;
        char *unloadArgs[] = {(char *)"launchctl", (char *)"unload",
                              (char *)"/Library/LaunchDaemons/com.hogan.trollshot.plist", NULL};
        if (posix_spawn(&unloadPid, "/bin/launchctl", NULL, NULL, unloadArgs, NULL) == 0) {
            int st = 0;
            waitpid(unloadPid, &st, 0);
        }

        [[TSLogger sharedLogger] log:@"launchd 已卸载，退出 daemon..."];

        /* 等待 HTTP 响应发送完毕 */
        usleep(150000); /* 150ms */

        exit(0);
    }
    return NULL;
}

static void HandleClientConnection(int client) {
    @autoreleasepool {
        char buf[4096];
        ssize_t n = recv(client, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            close(client);
            return;
        }
        buf[n] = '\0';

        [[TSLogger sharedLogger] log:@"收到 HTTP 请求"];

        /* /ping：健康检查，返回 pong（供 App 验证 daemon 是否真正运行） */
        if (strncmp(buf, "GET /ping", 9) == 0) {
            const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: close\r\n\r\npong";
            send(client, resp, strlen(resp), 0);
            close(client);
            return;
        }

        /* /shutdown：daemon 自行卸载 launchd 并退出（越狱环境，root 权限） */
        if (strncmp(buf, "GET /shutdown", 13) == 0) {
            const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 18\r\nConnection: close\r\n\r\nShutting down...\n";
            send(client, resp, strlen(resp), 0);
            close(client);
            [[TSLogger sharedLogger] log:@"处理 /shutdown 请求"];
            /* 在独立线程中执行关闭，确保 HTTP 响应已发送 */
            pthread_t shutdownThread;
            pthread_create(&shutdownThread, NULL, ShutdownThreadEntry, NULL);
            pthread_detach(shutdownThread);
            return;
        }

        /* 解析 URL 查询参数：rotate=1 强制旋转，crop=x1,y1,x2,y2 裁剪区域 */
        BOOL doRotate = NO;
        CGRect cropRect = CGRectZero;
        if (strncmp(buf, "GET /screenshot", 15) == 0) {
            /* 检查是否有 rotate=1 参数 */
            if (strstr(buf, "rotate=1")) {
                doRotate = YES;
            }
            /* 解析 crop=x1,y1,x2,y2 参数（左上角x,y + 右下角x,y） */
            char *cropStr = strstr(buf, "crop=");
            if (cropStr) {
                int cx1 = -1, cy1 = -1, cx2 = -1, cy2 = -1;
                int parsed = sscanf(cropStr + 5, "%d,%d,%d,%d", &cx1, &cy1, &cx2, &cy2);
                if (parsed == 4 && cx1 >= 0 && cy1 >= 0 && cx2 > cx1 && cy2 > cy1) {
                    cropRect = CGRectMake(cx1, cy1, cx2 - cx1, cy2 - cy1);
                }
            }
        } else {
            NSData *empty = [NSData data];
            SendResponse(client, 404, nil, empty);
            close(client);
            [[TSLogger sharedLogger] log:@"请求路径不匹配，返回 404"];
            return;
        }

        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"开始截图... rotate=%d crop=%@",
            doRotate, CGRectIsEmpty(cropRect) ? @"无" : [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f",
                cropRect.origin.x, cropRect.origin.y,
                cropRect.origin.x + cropRect.size.width,
                cropRect.origin.y + cropRect.size.height]]];
        NSError *captureError = nil;
        NSData *jpeg = [[ScreenCapturer sharedCapturer] captureJPEGWithQuality:0.85 rotate:doRotate cropRect:cropRect error:&captureError];
        if (captureError) {
            [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"截图失败: %@", captureError.localizedDescription]];
        }
        if (!jpeg) {
            NSData *empty = [NSData data];
            SendResponse(client, 500, nil, empty);
            close(client);
            return;
        }

        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"截图成功，大小 %lu 字节", (unsigned long)jpeg.length]];

        /* 诊断：在响应头输出图像尺寸信息 */
        NSMutableString *header = [NSMutableString string];
        [header appendFormat:@"HTTP/1.1 200 OK\r\n"];
        [header appendFormat:@"Content-Type: image/jpeg\r\n"];
        [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)jpeg.length];
        [header appendFormat:@"X-Orig-Size: %zux%zu\r\n", g_lastOrigWidth, g_lastOrigHeight];
        [header appendFormat:@"X-Final-Size: %zux%zu\r\n", g_lastFinalWidth, g_lastFinalHeight];
        [header appendFormat:@"X-Rotated: %s\r\n", g_lastRotated ? "YES" : "NO"];
        if (!CGRectIsEmpty(cropRect)) {
            [header appendFormat:@"X-Crop: %.0f,%.0f,%.0f,%.0f\r\n",
                cropRect.origin.x, cropRect.origin.y,
                cropRect.origin.x + cropRect.size.width,
                cropRect.origin.y + cropRect.size.height];
        } else {
            [header appendString:@"X-Crop: none\r\n"];
        }
        [header appendString:@"Connection: close\r\n"];
        [header appendString:@"Cache-Control: no-store\r\n"];
        [header appendString:@"\r\n"];

        const char *headerBytes = header.UTF8String;
        send(client, headerBytes, strlen(headerBytes), 0);
        send(client, jpeg.bytes, jpeg.length, 0);
        close(client);
    }
}

extern "C" void StartScreenshotServer(uint16_t port) {
    NSLog(@"[TrollShot] StartScreenshotServer 开始, port=%d", port);
    [[TSLogger sharedLogger] log:@"HTTP 服务线程启动"];

    int serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (serverSocket < 0) {
        NSLog(@"[TrollShot] socket() 失败: %s", strerror(errno));
        [[TSLogger sharedLogger] log:@"创建 socket 失败"];
        return;
    }
    NSLog(@"[TrollShot] socket() OK: fd=%d", serverSocket);

    int yes = 1;
    setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    /* bind 重试：端口可能被旧进程占用，等待释放后重试 */
    BOOL bindOK = NO;
    for (int retry = 0; retry < 10; retry++) {
        if (bind(serverSocket, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            bindOK = YES;
            break;
        }
        NSLog(@"[TrollShot] bind() 失败(重试 %d/10): %s (errno=%d)", retry + 1, strerror(errno), errno);
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"端口 %d 绑定失败(重试 %d/10)", port, retry + 1]];
        usleep(300000); /* 300ms */
    }
    if (!bindOK) {
        NSLog(@"[TrollShot] bind() 最终失败，放弃: %s", strerror(errno));
        [[TSLogger sharedLogger] log:@"端口绑定失败，10次重试后放弃"];
        close(serverSocket);
        return;
    }
    NSLog(@"[TrollShot] bind() OK");

    if (listen(serverSocket, 128) < 0) {
        NSLog(@"[TrollShot] listen() 失败: %s", strerror(errno));
        [[TSLogger sharedLogger] log:@"监听失败"];
        close(serverSocket);
        return;
    }
    NSLog(@"[TrollShot] listen() OK - 端口 %d 就绪", port);

    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"HTTP 服务器已在端口 %d 监听，最大并发 %d", port, kMaxConcurrentRequests]];

    gConcurrencySem = dispatch_semaphore_create(kMaxConcurrentRequests);
    if (!gConcurrencySem) {
        NSLog(@"[TrollShot] dispatch_semaphore_create 失败");
        [[TSLogger sharedLogger] log:@"初始化并发控制信号量失败"];
        close(serverSocket);
        return;
    }

    NSLog(@"[TrollShot] 进入 accept 循环");
    while (1) {
        int client = accept(serverSocket, NULL, NULL);
        if (client < 0)
            continue;

        /* 如果并发数已满，直接返回 503，避免无限创建线程 */
        if (dispatch_semaphore_wait(gConcurrencySem, DISPATCH_TIME_NOW) != 0) {
            const char *resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            send(client, resp, strlen(resp), 0);
            close(client);
            [[TSLogger sharedLogger] log:@"并发请求已满，返回 503"];
            continue;
        }

        /* 每个连接用独立 pthread 处理，避免 GCD 在 daemon 里不工作 */
        struct ClientContext *ctx = (struct ClientContext *)malloc(sizeof(struct ClientContext));
        ctx->clientSocket = client;
        pthread_t clientThread;
        pthread_create(&clientThread, NULL, HandleClientThread, ctx);
        pthread_detach(clientThread);
    }
}
