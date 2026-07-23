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
#import <semaphore.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

/* 最大并发截图请求数，避免高并发时创建过多线程导致系统拒绝连接 */
static const int kMaxConcurrentRequests = 4;
static sem_t gConcurrencySem;

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
            sem_post(&gConcurrencySem);
        }
        return NULL;
    }
}

static NSData *CaptureJPEGOnMainThread(void) {
    __block NSData *data = nil;
    __block NSError *error = nil;
    if ([NSThread isMainThread]) {
        data = [[ScreenCapturer sharedCapturer] captureJPEGWithQuality:0.85 error:&error];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            data = [[ScreenCapturer sharedCapturer] captureJPEGWithQuality:0.85 error:&error];
        });
    }
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

        if (strncmp(buf, "GET /screenshot", 15) != 0) {
            NSData *empty = [NSData data];
            SendResponse(client, 404, nil, empty);
            close(client);
            [[TSLogger sharedLogger] log:@"请求路径不匹配，返回 404"];
            return;
        }

        [[TSLogger sharedLogger] log:@"开始截图..."];
        NSData *jpeg = CaptureJPEGOnMainThread();
        if (!jpeg) {
            NSData *empty = [NSData data];
            SendResponse(client, 500, nil, empty);
            close(client);
            return;
        }

        [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"截图成功，大小 %lu 字节", (unsigned long)jpeg.length]];
        SendResponse(client, 200, @"image/jpeg", jpeg);
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

    if (sem_init(&gConcurrencySem, 0, kMaxConcurrentRequests) != 0) {
        [[TSLogger sharedLogger] log:@"初始化并发控制信号量失败"];
        close(serverSocket);
        return;
    }

    while (1) {
        int client = accept(serverSocket, NULL, NULL);
        if (client < 0)
            continue;

        /* 如果并发数已满，直接返回 503，避免无限创建线程 */
        if (sem_trywait(&gConcurrencySem) != 0) {
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
