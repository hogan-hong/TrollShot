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
#import <sys/stat.h>
#import <spawn.h>
#import <stdlib.h>

/* 最大并发截图请求数
 * 越狱模式：串行（1），避免 framebuffer 直读并发冲突
 * 非越狱模式：4（原值），CARenderServer 可并发 */
static int gMaxConcurrent = 4;
static dispatch_semaphore_t gConcurrencySem;

/* HandleClientConnection 在下方定义，线程入口需要前向声明 */
static void HandleClientConnection(int client);

/* 客户端连接参数 */
struct ClientContext {
    int clientSocket;
};

/* 客户端处理线程入口
 * 并发 semaphore 的 acquire/release 已移入 HandleClientConnection 内部，
 * 仅包裹 /screenshot 截图逻辑；/ping、/status 等轻量请求不受限制。 */
static void *HandleClientThread(void *arg) {
    @autoreleasepool {
        struct ClientContext *ctx = (struct ClientContext *)arg;
        int client = ctx->clientSocket;
        free(ctx);
        HandleClientConnection(client);
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
        [[TSLogger sharedLogger] log:@"收到关闭请求，写入停止标志并退出..."];

        /* 写入停止标志，wrapper 脚本检测到后不会重启 daemon */
        mkdir("/var/mobile/trollshot", 0755);
            FILE *f = fopen("/var/mobile/trollshot/stop.flag", "w");
        if (f) {
            fclose(f);
            chmod("/var/mobile/trollshot/stop.flag", 0666);
        }

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

        /* /status：返回截图服务和镜像状态（JSON） */
        if (strncmp(buf, "GET /status", 11) == 0) {
            BOOL mirror = [ScreenCapturer isMirrorActive];
            BOOL needsMirror = [ScreenCapturer needsMirror];
            NSString *mode;
            if (g_isJailbreakMode) {
                mode = g_useFramebuffer ? @"framebuffer" : @"carender";
            } else {
                mode = @"carender";
            }
            /* status: ok = 可正常截图; need_mirror = 需要开启AirPlay镜像; fb_fail = framebuffer失败降级 */
            NSString *status;
            if (g_isJailbreakMode && g_useFramebuffer && !mirror) {
                status = @"need_mirror";
            } else {
                status = @"ok";
            }
            NSString *json = [NSString stringWithFormat:
                @"{\"mode\":\"%@\",\"jailbreak\":%@,\"mirror\":%@,\"needs_mirror\":%@,\"status\":\"%@\"}",
                mode,
                g_isJailbreakMode ? @"true" : @"false",
                mirror ? @"true" : @"false",
                needsMirror ? @"true" : @"false",
                status];
            NSData *body = [json dataUsingEncoding:NSUTF8StringEncoding];
            SendResponse(client, 200, @"application/json", body);
            close(client);
            return;
        }

        /* /stop：daemon 退出但保留 launchd，wrapper 通过标志文件决定是否重启
         * 用于 app 停止/启动服务，不需要 root 权限操作 launchctl */
        if (strncmp(buf, "GET /stop", 9) == 0) {
            const char *resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\nConnection: close\r\n\r\nstopped\n";
            send(client, resp, strlen(resp), 0);
            close(client);
            [[TSLogger sharedLogger] log:@"处理 /stop 请求，写入停止标志并退出"];
            /* 写入停止标志，wrapper 脚本检测到后不会重启 */
            mkdir("/var/mobile/trollshot", 0755);
            FILE *f = fopen("/var/mobile/trollshot/stop.flag", "w");
            if (f) {
                fclose(f);
                chmod("/var/mobile/trollshot/stop.flag", 0666);
            }
            /* 等待 HTTP 响应发送完毕 */
            usleep(150000);
            exit(0);
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

        /* 非截图路径一律 404（/ping、/status、/stop、/shutdown 已在上方处理） */
        if (strncmp(buf, "GET /screenshot", 15) != 0) {
            NSData *empty = [NSData data];
            SendResponse(client, 404, nil, empty);
            close(client);
            [[TSLogger sharedLogger] log:@"请求路径不匹配，返回 404"];
            return;
        }

        /* 并发限制仅作用于 /screenshot（越狱 framebuffer 直读不可并发）。
         * 并发已满时立即返回 503 + X-Busy 头（区别于镜像未开的 503 X-Mirror-Status 头）。 */
        if (dispatch_semaphore_wait(gConcurrencySem, DISPATCH_TIME_NOW) != 0) {
            const char *resp = "HTTP/1.1 503 Service Unavailable\r\n"
                "Content-Type: application/json\r\n"
                "X-Busy: true\r\n"
                "Connection: close\r\n"
                "\r\n"
                "{\"error\":\"busy\",\"message\":\"截图请求并发已满，请稍后重试\"}";
            send(client, resp, strlen(resp), 0);
            close(client);
            [[TSLogger sharedLogger] log:@"截图并发已满，返回 503"];
            return;
        }

        @try {
        /* 解析 URL 查询参数：rotate=1 强制旋转，crop=x1,y1,x2,y2 裁剪区域 */
        BOOL doRotate = NO;
        CGRect cropRect = CGRectZero;
        {
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
        }

        /* 越狱 framebuffer 模式：检查 AirPlay 镜像是否开启 */
        if (g_isJailbreakMode && g_useFramebuffer && ![ScreenCapturer isMirrorActive]) {
            const char *resp = "HTTP/1.1 503 Service Unavailable\r\n"
                "Content-Type: application/json\r\n"
                "Connection: close\r\n"
                "X-Mirror-Status: inactive\r\n"
                "\r\n"
                "{\"error\":\"airplay_mirror_not_active\",\"message\":\"AirPlay屏幕镜像未开启，无法截图\"}";
            send(client, resp, strlen(resp), 0);
            close(client);
            [[TSLogger sharedLogger] log:@"截图失败：AirPlay镜像未开启，返回503"];
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
        } @finally {
            /* 截图流程结束（含失败/镜像未开提前返回），释放并发信号量 */
            dispatch_semaphore_signal(gConcurrencySem);
        }
    }
}

extern "C" void StartScreenshotServer(uint16_t port) {
    NSLog(@"[TrollShot] StartScreenshotServer 开始, port=%d", port);
    [[TSLogger sharedLogger] log:@"HTTP 服务线程启动"];

    /* 触发 ScreenCapturer 初始化，检测越狱模式并设置并发数 */
    [ScreenCapturer sharedCapturer];
    if (g_isJailbreakMode) {
        gMaxConcurrent = 1; /* 越狱模式串行，避免 framebuffer 并发冲突 */
    }
    NSString *modeStr;
    if (g_isJailbreakMode) {
        modeStr = g_useFramebuffer ? @"越狱 framebuffer 直读（需AirPlay镜像）" : @"越狱 CARenderServer（framebuffer降级）";
    } else {
        modeStr = @"非越狱 CARenderServer";
    }
    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"截图模式：%@（uid=%d，并发=%d）",
        modeStr, getuid(), gMaxConcurrent]];

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

    [[TSLogger sharedLogger] log:[NSString stringWithFormat:@"HTTP 服务器已在端口 %d 监听，最大并发 %d%@", port, gMaxConcurrent, g_isJailbreakMode ? @"（越狱串行）" : @""]];

    gConcurrencySem = dispatch_semaphore_create(gMaxConcurrent);
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

        /* 每个连接用独立 pthread 处理，避免 GCD 在 daemon 里不工作。
         * 并发 semaphore 只在 HandleClientConnection 内部作用于 /screenshot，
         * /ping、/status 等轻量请求不受限制，避免截图期间 App 状态误判为"未运行"。 */
        struct ClientContext *ctx = (struct ClientContext *)malloc(sizeof(struct ClientContext));
        ctx->clientSocket = client;
        pthread_t clientThread;
        pthread_create(&clientThread, NULL, HandleClientThread, ctx);
        pthread_detach(clientThread);
    }
}
