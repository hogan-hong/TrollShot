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

#import <arpa/inet.h>
#import <netinet/in.h>
#import <pthread.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

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
static NSData *CaptureJPEG(void) {
    __block NSData *data = nil;
    __block NSError *error = nil;
    data = [[ScreenCapturer sharedCapturer] captureJPEGWithQuality:0.85 error:&error];
    if (error) {
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"截图失败: %@", error.localizedDescription]];
    }
    return data;
}

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

        /* 解析 URL 查询参数，支持 /screenshot?rotate=1 */
        BOOL doRotate = NO;
        if (strncmp(buf, "GET /screenshot", 15) == 0) {
            /* 检查是否有 rotate=1 参数 */
            char *query = strstr(buf, "rotate=1");
            if (query) {
                doRotate = YES;
            }
        } else {
            NSData *empty = [NSData data];
            SendResponse(client, 404, nil, empty);
            close(client);
            [[TSLogger sharedLogger] log:@"请求路径不匹配，返回 404"];
            return;
        }

        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"开始截图... rotate=%d", doRotate]];
        NSError *captureError = nil;
        NSData *jpeg = [[ScreenCapturer sharedCapturer] captureJPEGWithQuality:0.85 rotate:doRotate error:&captureError];
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
    [[TSLogger sharedLogger] log:@"HTTP 服务线程启动"];

    int serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (serverSocket < 0) {
        [[TSLogger sharedLogger] log:@"创建 socket 失败"];
        return;
    }

    int yes = 1;
    setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"端口 %d 绑定失败", port]];
        close(serverSocket);
        return;
    }

    if (listen(serverSocket, 128) < 0) {
        [[TSLogger sharedLogger] log:@"监听失败"];
        close(serverSocket);
        return;
    }

    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"HTTP 服务器已在端口 %d 监听，最大并发 %d", port, kMaxConcurrentRequests]];

    gConcurrencySem = dispatch_semaphore_create(kMaxConcurrentRequests);
    if (!gConcurrencySem) {
        [[TSLogger sharedLogger] log:@"初始化并发控制信号量失败"];
        close(serverSocket);
        return;
    }

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
