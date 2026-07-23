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
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

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

    if (listen(serverSocket, 5) < 0) {
        [[TSLogger sharedLogger] log:@"监听失败"];
        close(serverSocket);
        return;
    }

    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"HTTP 服务器已在端口 %d 监听", port]];

    while (1) {
        int client = accept(serverSocket, NULL, NULL);
        if (client < 0)
            continue;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            HandleClientConnection(client);
        });
    }
}
