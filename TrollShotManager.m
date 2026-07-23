/*
 This file is part of TrollShot, derived from TrollVNC.
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TrollShotManager.h"

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <signal.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>

#define kDaemonName        @"trollshotd"
#define kLaunchdPlistName  @"com.hogan.trollshot.plist"
#define kDaemonDestDir     @"/usr/bin"
#define kLogDir            @"/var/mobile/trollshot"
#define kListenPort        8080

@implementation TrollShotManager

+ (instancetype)sharedManager {
    static TrollShotManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

/* 获取 TrollShot.app 的路径 */
- (NSString *)bundlePath {
    return [[NSBundle mainBundle] bundlePath];
}

/* 获取 IPA 内部的 daemon 路径 */
- (NSString *)bundledDaemonPath {
    return [[self bundlePath] stringByAppendingPathComponent:kDaemonName];
}

/* 获取 IPA 内部的 launchd plist 路径 */
- (NSString *)bundledPlistPath {
    return [[self bundlePath] stringByAppendingPathComponent:kLaunchdPlistName];
}

/* daemon 目标路径（postinst 安装到 /usr/bin） */
- (NSString *)installedDaemonPath {
    return [kDaemonDestDir stringByAppendingPathComponent:kDaemonName];
}

/* launchd plist 目标路径 */
- (NSString *)installedPlistPath {
    return [@"/Library/LaunchDaemons" stringByAppendingPathComponent:kLaunchdPlistName];
}

/* PID 文件路径 */
- (NSString *)pidFilePath {
    return [kLogDir stringByAppendingPathComponent:@"trollshotd.pid"];
}

/* 保存 daemon PID */
- (void)savePid:(pid_t)pid {
    NSString *pidStr = [NSString stringWithFormat:@"%d", pid];
    [pidStr writeToFile:[self pidFilePath]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];
}

/* 读取 PID 文件 */
- (pid_t)readSavedPid {
    NSString *pidStr = [NSString stringWithContentsOfFile:[self pidFilePath]
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    return pidStr ? (pid_t)[pidStr intValue] : 0;
}

/* 创建目录（不强制 root/wheel，避免 TrollStore 权限不足） */
- (BOOL)ensureDirectory:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return [fm createDirectoryAtPath:path
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:error];
    }
    if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@ 已存在但不是目录", path]}];
        }
        return NO;
    }
    return YES;
}

/* 判断 daemon 是否已通过 postinst 安装到系统目录 */
- (BOOL)isDaemonInstalled {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL hasBin = [fm fileExistsAtPath:[self installedDaemonPath] isDirectory:&isDir] && !isDir;
    BOOL hasPlist = [fm fileExistsAtPath:[self installedPlistPath]];
    return hasBin && hasPlist;
}

/* 通过连接本地端口判断服务是否正在运行 */
- (BOOL)isDaemonRunning {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kListenPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int result = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
    close(sockfd);
    if (result == 0) return YES;

    /* 如果连不上，再检查之前保存的 PID 是否仍存活 */
    pid_t pid = [self readSavedPid];
    if (pid > 0 && kill(pid, 0) == 0) {
        return YES;
    }
    return NO;
}

/* 启动 daemon：依赖 postinst 已将二进制和 plist 安装到系统目录 */
- (BOOL)startDaemon:(NSError **)error {
    if (!self.isDaemonInstalled) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey : @"未找到系统级安装。\n\nTrollShot 需要通过 .deb 包安装才能开机自启。请卸载当前 IPA，通过 TrollStore 安装最新 .deb 包。"}];
        }
        return NO;
    }

    if (self.isDaemonRunning) return YES;

    NSString *plistPath = [self installedPlistPath];

    /* 先尝试 launchctl load -w */
    int ret = [self spawnCommand:@"/bin/launchctl" arguments:@[@"load", @"-w", plistPath]];
    if (ret != 0) {
        /* 可能已加载，尝试启动 */
        ret = [self spawnCommand:@"/bin/launchctl" arguments:@[@"start", @"com.hogan.trollshot"]];
    }

    if (ret != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey : @"启动服务失败，请检查日志 /var/mobile/trollshot/trollshotd.log"}];
        }
        return NO;
    }

    /* 等待 1 秒确认服务端口已打开 */
    for (int i = 0; i < 20; i++) {
        if ([self isDaemonRunning]) return YES;
        [NSThread sleepForTimeInterval:0.05];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"TrollShot"
                                     code:3002
                                 userInfo:@{NSLocalizedDescriptionKey : @"服务已加载但端口未响应，请检查日志 /var/mobile/trollshot/trollshotd.log"}];
    }
    return NO;
}

/* 等待进程退出 */
- (BOOL)waitForProcessExit:(pid_t)pid timeout:(NSTimeInterval)timeout {
    NSTimeInterval elapsed = 0;
    while (elapsed < timeout) {
        if (kill(pid, 0) != 0) return YES;
        [NSThread sleepForTimeInterval:0.05];
        elapsed += 0.05;
    }
    return kill(pid, 0) != 0;
}

/* 停止 daemon */
- (BOOL)stopDaemon:(NSError **)error {
    NSString *plistPath = [self installedPlistPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        [self spawnCommand:@"/bin/launchctl" arguments:@[@"unload", @"-w", plistPath]];
    }

    pid_t pid = [self readSavedPid];
    if (pid > 0 && kill(pid, 0) == 0) {
        kill(pid, SIGTERM);
        if (![self waitForProcessExit:pid timeout:1.0]) {
            kill(pid, SIGKILL);
            [self waitForProcessExit:pid timeout:0.5];
        }
    }

    /* 兜底：结束所有 trollshotd 进程 */
    [self killDaemonProcesses];

    [[NSFileManager defaultManager] removeItemAtPath:[self pidFilePath] error:nil];
    return YES;
}

/* 使用 posix_spawn 执行命令 */
- (int)spawnCommand:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    const char *cPath = [path fileSystemRepresentation];
    int argc = (int)arguments.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    argv[0] = strdup(cPath);
    for (int i = 0; i < (int)arguments.count; i++) {
        argv[i + 1] = strdup([arguments[i] fileSystemRepresentation]);
    }
    argv[argc] = NULL;

    pid_t pid = 0;
    int ret = posix_spawn(&pid, cPath, NULL, NULL, argv, NULL);

    for (int i = 0; i <= argc; i++) {
        if (argv[i]) free(argv[i]);
    }
    free(argv);

    if (ret != 0) return -1;

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

/* 兜底结束 trollshotd 进程 */
- (BOOL)killDaemonProcesses {
    return [self spawnCommand:@"/usr/bin/killall" arguments:@[@"-9", kDaemonName]] == 0;
}

@end
