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
#define kDaemonDestDir     @"/var/mobile/trollshot"
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

/* daemon 目标路径 */
- (NSString *)installedDaemonPath {
    return [kDaemonDestDir stringByAppendingPathComponent:kDaemonName];
}

/* launchd plist 目标路径（保留，供高级用户使用） */
- (NSString *)installedPlistPath {
    return [kDaemonDestDir stringByAppendingPathComponent:kLaunchdPlistName];
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

/* 判断 daemon 是否已安装 */
- (BOOL)isDaemonInstalled {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:[self installedDaemonPath] isDirectory:&isDir] && !isDir;
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

/* 安装 daemon 到 /var/mobile/trollshot */
- (BOOL)installDaemon:(NSError **)error {
    NSString *srcBin = [self bundledDaemonPath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:srcBin]) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey : @"应用内未找到 trollshotd，请重新安装 IPA"}];
        }
        return NO;
    }

    if (![self ensureDirectory:kLogDir error:error]) return NO;
    if (![self ensureDirectory:kDaemonDestDir error:error]) return NO;

    NSError *copyErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:[self installedDaemonPath] error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:srcBin
                                                 toPath:[self installedDaemonPath]
                                                  error:&copyErr]) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:2003
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"复制 trollshotd 失败: %@\n源: %@\n目标: %@", copyErr.localizedDescription, srcBin, [self installedDaemonPath]]}];
        }
        return NO;
    }

    chmod([[self installedDaemonPath] fileSystemRepresentation], 0755);
    return YES;
}

/* 直接启动 daemon 进程 */
- (BOOL)launchDaemonProcess:(NSError **)error {
    NSString *daemonPath = [self installedDaemonPath];
    const char *cPath = [daemonPath fileSystemRepresentation];
    NSArray<NSString *> *args = @[@"--port", @"8080"];
    int argc = (int)args.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    argv[0] = strdup(cPath);
    for (int i = 0; i < (int)args.count; i++) {
        argv[i + 1] = strdup([args[i] fileSystemRepresentation]);
    }
    argv[argc] = NULL;

    /* 重定向 stdout/stderr 到日志文件 */
    NSString *logPath = [kLogDir stringByAppendingPathComponent:@"trollshotd.log"];
    int logFd = open([logPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (logFd >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFd);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    pid_t pid = 0;
    int ret = posix_spawn(&pid, cPath, logFd >= 0 ? &actions : NULL, &attr, argv, NULL);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    if (logFd >= 0) close(logFd);

    for (int i = 0; i <= argc; i++) {
        if (argv[i]) free(argv[i]);
    }
    free(argv);

    if (ret != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"启动 trollshotd 失败: %s", strerror(ret)]}];
        }
        return NO;
    }

    [self savePid:pid];
    return YES;
}

/* 启动 daemon */
- (BOOL)startDaemon:(NSError **)error {
    if (!self.isDaemonInstalled) {
        if (![self installDaemon:error]) return NO;
    }

    if (self.isDaemonRunning) return YES;

    if (![self launchDaemonProcess:error]) return NO;

    /* 等待 0.5 秒确认服务端口已打开 */
    for (int i = 0; i < 10; i++) {
        if ([self isDaemonRunning]) return YES;
        [NSThread sleepForTimeInterval:0.05];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"TrollShot"
                                     code:3002
                                 userInfo:@{NSLocalizedDescriptionKey : @"trollshotd 已启动但端口未响应，请检查日志 /var/mobile/trollshot/trollshotd.log"}];
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
    /* 先尝试 launchctl unload，供已手动放置 plist 到 LaunchDaemons 的用户使用 */
    [self spawnLaunchctlUnload];

    pid_t pid = [self readSavedPid];
    if (pid > 0 && kill(pid, 0) == 0) {
        kill(pid, SIGTERM);
        if (![self waitForProcessExit:pid timeout:1.0]) {
            kill(pid, SIGKILL);
            [self waitForProcessExit:pid timeout:0.5];
        }
    }

    /* 党底：查找并结束所有 trollshotd 进程 */
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

/* 尝试 launchctl unload */
- (void)spawnLaunchctlUnload {
    NSString *plistPath = [self installedPlistPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        [self spawnCommand:@"/bin/launchctl" arguments:@[@"unload", @"-w", plistPath]];
    }
}

/* 兜底结束 trollshotd 进程 */
- (BOOL)killDaemonProcesses {
    return [self spawnCommand:@"/usr/bin/killall" arguments:@[@"-9", kDaemonName]] == 0;
}

/* 卸载 daemon */
- (BOOL)uninstallDaemon:(NSError **)error {
    [self stopDaemon:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self installedDaemonPath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self installedPlistPath] error:nil];
    return YES;
}

@end
