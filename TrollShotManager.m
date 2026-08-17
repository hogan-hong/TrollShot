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
#import <dlfcn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>

/* 私有 API：以 root 身份启动进程（越狱环境内核补丁支持）
 * Filza、NewTerm 等越狱 app 通用方案
 * 非越狱环境此调用会被忽略，进程以当前用户(mobile)启动 */
#define POSIX_SPAWN_PERSONA_STARTS_AS_ROOT 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict,
    uid_t, uint32_t, const char *__restrict,
    const char *__restrict, uint32_t);
/* setgroups_np 在 SDK 中不可用，用 dlsym 动态加载 */

#define kDaemonName        @"trollshotd"
#define kLaunchdPlistName  @"com.hogan.trollshot.plist"
#define kDaemonDestDir     @"/var/mobile/trollshot"
#define kLogDir            @"/var/mobile/trollshot"
#define kDefaultPort       6688
#define kApiPortFile       @"/var/mobile/trollshot/api_port"
#define kAutolinkPlist     @"/var/mobile/Library/Preferences/com.hoganhong.airplay-autolink.plist"
#define kDefaultAirplayName @"TrollShot"
#define kDebugFlagFile     @"/var/mobile/trollshot/debug_mode"
#define kSystemPlistPath   @"/Library/LaunchDaemons/com.hogan.trollshot.plist"

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

/* 读取调试模式标志 */
+ (BOOL)isDebugMode {
    NSString *content = [NSString stringWithContentsOfFile:kDebugFlagFile
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    return [[content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:@"1"];
}

/* 设置调试模式标志，写入标志文件。返回是否写入成功 */
+ (BOOL)setDebugMode:(BOOL)enabled {
    /* 确保目录存在（越狱模式下可能尚未创建） */
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kDaemonDestDir]) {
        [fm createDirectoryAtPath:kDaemonDestDir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
    }
    NSString *content = enabled ? @"1" : @"0";
    NSError *writeErr = nil;
    BOOL ok = [content writeToFile:kDebugFlagFile
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:&writeErr];
    if (!ok) {
        NSLog(@"[TrollShot] setDebugMode(%d) 写文件失败: %@", enabled, writeErr);
    }
    return ok;
}

/* 清空日志文件 */
+ (void)clearLogFile {
    NSString *logPath = [kLogDir stringByAppendingPathComponent:@"trollshotd.log"];
    [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

/* 读取 API 端口（默认 6688，非法值回退默认） */
+ (NSInteger)apiPort {
    NSString *content = [NSString stringWithContentsOfFile:kApiPortFile
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    NSInteger p = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].integerValue;
    return (p >= 1 && p <= 65535) ? p : kDefaultPort;
}

/* 设置 API 端口，写入标志文件。返回是否写入成功 */
+ (BOOL)setApiPort:(NSInteger)port {
    if (port < 1 || port > 65535) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kDaemonDestDir]) {
        [fm createDirectoryAtPath:kDaemonDestDir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
    }
    NSString *content = [NSString stringWithFormat:@"%ld", (long)port];
    return [content writeToFile:kApiPortFile
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
}

/* 读取 AirPlay 服务器名（默认 TrollShot） */
+ (NSString *)airplayServerName {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:kAutolinkPlist];
    NSString *n = p[@"target"];
    return ([n isKindOfClass:[NSString class]] && n.length > 0) ? n : kDefaultAirplayName;
}

/* 设置 AirPlay 服务器名，写入 tweak 的 plist target 键（保留其他键）。
 * tweak 断开转变时热加载，即时生效 */
+ (BOOL)setAirplayServerName:(NSString *)name {
    if (name.length == 0) return NO;
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:kAutolinkPlist];
    NSMutableDictionary *p = [NSMutableDictionary dictionaryWithDictionary:(old ?: @{})];
    p[@"target"] = name;
    return [p writeToFile:kAutolinkPlist atomically:YES];
}

/* 服务是否被用户主动停止（stop.flag 存在，wrapper 检测到后不会拉起 daemon） */
+ (BOOL)isServiceStoppedByUser {
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/trollshot/stop.flag"];
}

/* 端口文件更新后调用，让 daemon 切到新端口 */
- (BOOL)applyPortChange {
    /* deb 环境：wrapper 脚本监视端口文件，检测到变化即自动重启 daemon，
     * 这里只需等新端口就绪（最多 6 秒） */
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSystemPlistPath]) {
        if ([TrollShotManager isServiceStoppedByUser]) {
            /* 服务被主动停止：保持停止，下次启动服务时用新端口 */
            return YES;
        }
        for (int i = 0; i < 60; i++) {
            if ([self isDaemonRunning]) return YES;
            [NSThread sleepForTimeInterval:0.1];
        }
        return [self isDaemonRunning];
    }

    /* TrollStore 环境：无 wrapper，清理旧端口进程后按新端口重新拉起 */
    if (![self isDaemonRunning]) return YES;
    [self killDaemonProcesses];
    [NSThread sleepForTimeInterval:0.2];
    return [self startDaemon:nil];
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

/* 通过 HTTP /ping 请求验证 daemon 是否真正运行（不仅检查端口，还验证响应） */
- (BOOL)isDaemonRunning {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((int)[TrollShotManager apiPort]);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    /* 1 秒超时，避免 UI 卡顿 */
    struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
    setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        return NO;
    }

    /* 发送 /ping 请求，验证是 trollshotd 而非其他服务 */
    const char *req = "GET /ping HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n";
    if (send(sockfd, req, strlen(req), 0) <= 0) {
        close(sockfd);
        return NO;
    }

    char buf[256];
    memset(buf, 0, sizeof(buf));
    ssize_t n = recv(sockfd, buf, sizeof(buf) - 1, 0);
    close(sockfd);

    if (n <= 0) return NO;

    /* 检查响应中是否包含 "pong" */
    return strstr(buf, "pong") != NULL;
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

    /* 同时复制 launchd plist 到 /var/mobile/trollshot/ */
    NSString *srcPlist = [self bundledPlistPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:srcPlist]) {
        NSString *dstPlist = [self installedPlistPath];
        [[NSFileManager defaultManager] removeItemAtPath:dstPlist error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:srcPlist toPath:dstPlist error:nil];
    }

    /* 尝试复制 plist 到 /Library/LaunchDaemons/（越狱环境可能可写） */
    if ([[NSFileManager defaultManager] fileExistsAtPath:srcPlist]) {
        NSString *sysDir = @"/Library/LaunchDaemons";
        NSString *sysPlist = [sysDir stringByAppendingPathComponent:kLaunchdPlistName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:sysPlist]) {
            /* 尝试直接复制（no-sandbox 可能允许写入） */
            NSError *sysCopyErr = nil;
            BOOL sysOk = [[NSFileManager defaultManager] copyItemAtPath:srcPlist
                                                                  toPath:sysPlist
                                                                   error:&sysCopyErr];
            if (sysOk) {
                NSLog(@"[TrollShot] plist 已复制到系统 LaunchDaemons 目录");
            } else {
                NSLog(@"[TrollShot] 无法复制到系统 LaunchDaemons（权限不足）: %@", sysCopyErr.localizedDescription);
            }
        }
    }

    return YES;
}

/* 直接启动 daemon 进程（从 .app bundle 内运行，保持代码签名有效） */
- (BOOL)launchDaemonProcess:(NSError **)error {
    /* 优先使用 .app bundle 内的 daemon（签名有效），避免复制到外部路径被 AMFI 杀掉 */
    NSString *daemonPath = [self bundledDaemonPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:daemonPath]) {
        /* 兜底：使用已安装路径（旧版本兼容） */
        daemonPath = [self installedDaemonPath];
    }
    const char *cPath = [daemonPath fileSystemRepresentation];

    /* 根据调试模式标志与配置端口决定启动参数 */
    BOOL debug = [TrollShotManager isDebugMode];
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
        @"--port", [NSString stringWithFormat:@"%ld", (long)[TrollShotManager apiPort]], nil];
    if (debug) {
        [args addObject:@"--debug"];
    }
    int argc = (int)args.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    argv[0] = strdup(cPath);
    for (int i = 0; i < (int)args.count; i++) {
        argv[i + 1] = strdup([args[i] fileSystemRepresentation]);
    }
    argv[argc] = NULL;

    /* 调试模式时重定向 stdout/stderr 到日志文件，否则丢弃输出 */
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    if (debug) {
        NSString *logPath = [kLogDir stringByAppendingPathComponent:@"trollshotd.log"];
        int logFd = open([logPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (logFd >= 0) {
            posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO);
            posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO);
            posix_spawn_file_actions_addclose(&actions, logFd);
        }
    } else {
        /* 非调试模式：丢弃 stdout/stderr 到 /dev/null */
        int devNull = open("/dev/null", O_WRONLY);
        if (devNull >= 0) {
            posix_spawn_file_actions_adddup2(&actions, devNull, STDOUT_FILENO);
            posix_spawn_file_actions_adddup2(&actions, devNull, STDERR_FILENO);
            posix_spawn_file_actions_addclose(&actions, devNull);
        }
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    /* 越狱环境：通过 persona API 以 root 身份启动 daemon
     * 这是越狱 app 获取 root 权限的标准方式
     * 非越狱环境调用会静默失败，进程以 mobile 启动 */
    /* 越狱环境：尝试通过 persona API 以 root 身份启动 daemon
     * 非越狱或内核不支持时，persona posix_spawn 返回 EPERM，降级为普通 spawn */
    BOOL usePersona = YES;
    int personaRet = posix_spawnattr_set_persona_np(&attr, 0, POSIX_SPAWN_PERSONA_STARTS_AS_ROOT, NULL, NULL, 0);
    if (personaRet != 0) {
        NSLog(@"[TrollShot] set_persona_np 失败: %d，降级为普通 spawn", personaRet);
        usePersona = NO;
    } else {
        /* dlsym 动态加载 setgroups_np（SDK 中不可用） */
        int (*setgroups_np)(const posix_spawnattr_t *, uint32_t, const gid_t *, uint32_t) =
            (int (*)(const posix_spawnattr_t *, uint32_t, const gid_t *, uint32_t))
            dlsym(RTLD_DEFAULT, "posix_spawnattr_setgroups_np");
        if (setgroups_np) {
            gid_t zeroGid = 0;
            setgroups_np(&attr, 1, &zeroGid, 0);
        }
        NSLog(@"[TrollShot] persona root spawn: setgroups_np=%p", setgroups_np);
    }

    pid_t pid = 0;
    int ret = posix_spawn(&pid, cPath, &actions, &attr, argv, NULL);

    /* persona spawn 失败（EPERM=内核不支持），降级为普通 spawn */
    if (ret == EPERM && usePersona) {
        NSLog(@"[TrollShot] persona posix_spawn 返回 EPERM，降级为普通 spawn（mobile 用户）");
        posix_spawnattr_destroy(&attr);
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
        ret = posix_spawn(&pid, cPath, &actions, &attr, argv, NULL);
    }

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);

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

    /* 检查进程是否立即崩溃（AMFI 代码签名杀进程） */
    [NSThread sleepForTimeInterval:0.2];
    int status = 0;
    pid_t waitResult = waitpid(pid, &status, WNOHANG);
    if (waitResult != 0) {
        /* 进程已退出 */
        NSString *crashReason;
        if (WIFSIGNALED(status)) {
            crashReason = [NSString stringWithFormat:@"trollshotd 被信号 %d 杀死（可能是代码签名/AMFI拒绝）", WTERMSIG(status)];
        } else {
            crashReason = [NSString stringWithFormat:@"trollshotd 退出码 %d", WEXITSTATUS(status)];
        }
        NSLog(@"[TrollShot] %@", crashReason);
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3004
                                     userInfo:@{NSLocalizedDescriptionKey : crashReason}];
        }
        return NO;
    }

    return YES;
}

/* 启动 daemon */
- (BOOL)startDaemon:(NSError **)error {
    /* 如果 daemon 已经在运行（例如 deb postinst 自动启动），直接返回成功 */
    if ([self isDaemonRunning]) return YES;

    /* 越狱环境：系统级 launchd plist 存在（deb 已安装）
     * daemon 由 launchd 管理的 wrapper 脚本运行，app 无需 root 权限。
     * 如果之前通过 app 停止了服务，删除停止标志文件，wrapper 脚本会自动重启 daemon */
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSystemPlistPath]) {
        /* 删除停止标志文件，让 wrapper 脚本重新启动 daemon */
        [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/trollshot/stop.flag" error:nil];
        /* 等待 wrapper 脚本检测到标志已删除并重启 daemon（最多 5 秒） */
        for (int i = 0; i < 50; i++) {
            if ([self isDaemonRunning]) return YES;
            [NSThread sleepForTimeInterval:0.1];
        }
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3002
                                     userInfo:@{NSLocalizedDescriptionKey : @"服务启动超时，wrapper 脚本可能未运行。请通过 SSH 检查：\nps aux | grep trollshotd_wrapper"}];
        }
        return NO;
    }

    /* 越狱环境：系统级 plist 不存在，尝试用用户级 plist 通过 launchctl 加载
     * plist 中指定了 UserName=root，launchd 可能以 root 启动 daemon
     * 这需要先 stop 旧进程，否则端口冲突 */
    NSString *userPlist = [self installedPlistPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:userPlist]) {
        /* 先清理旧进程 */
        [self killDaemonProcesses];
        [NSThread sleepForTimeInterval:0.3];

        /* 先 unload 旧实例（如果存在） */
        [self spawnCommand:@"/bin/launchctl" arguments:@[@"unload", userPlist]];
        [NSThread sleepForTimeInterval:0.2];

        /* 尝试 bootstrap system（新语法，以 root 域加载） */
        int ret = [self spawnCommand:@"/bin/launchctl" arguments:@[@"bootstrap", @"system", userPlist]];
        if (ret != 0) {
            /* 旧语法兜底 */
            ret = [self spawnCommand:@"/bin/launchctl" arguments:@[@"load", @"-w", userPlist]];
        }

        if (ret == 0) {
            /* 等待端口就绪 */
            for (int i = 0; i < 20; i++) {
                if ([self isDaemonRunning]) return YES;
                [NSThread sleepForTimeInterval:0.1];
            }
        }
        /* launchctl 失败，继续尝试 posix_spawn 兜底 */
        NSLog(@"[TrollShot] launchctl 加载用户级 plist 失败，回退到 posix_spawn");
    }

    /* TrollStore 环境：直接从 .app bundle 启动 daemon（不复制到外部路径，保持签名有效） */

    /* 先清理可能残留的旧 trollshotd 进程（之前版本复制到 /var/mobile/trollshot/ 的） */
    [self killDaemonProcesses];
    [NSThread sleepForTimeInterval:0.3];

    if (self.isDaemonRunning) return YES;

    if (![self launchDaemonProcess:error]) return NO;

    /* 等待最多 3 秒确认服务端口已打开 */
    for (int i = 0; i < 60; i++) {
        if ([self isDaemonRunning]) return YES;
        [NSThread sleepForTimeInterval:0.05];
    }

    /* 检查进程是否已崩溃 */
    pid_t pid = [self readSavedPid];
    BOOL crashed = (pid > 0 && kill(pid, 0) != 0);

    /* 读取日志内容，直接显示在错误信息中 */
    NSString *logPath = [kLogDir stringByAppendingPathComponent:@"trollshotd.log"];
    NSString *logContent = [NSString stringWithContentsOfFile:logPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    NSString *errorMsg;
    if (crashed) {
        errorMsg = @"trollshotd 启动后立即崩溃";
    } else {
        errorMsg = @"trollshotd 已启动但端口未响应（3秒超时）";
    }
    if (logContent.length > 0) {
        /* 截取最后 500 字符，避免弹窗过长 */
        NSString *tail = logContent.length > 500 ?
            [logContent substringFromIndex:logContent.length - 500] : logContent;
        errorMsg = [NSString stringWithFormat:@"%@\n\n--- 日志 ---\n%@", errorMsg, tail];
    } else {
        errorMsg = [NSString stringWithFormat:@"%@\n\n（日志为空，请先开启调试模式再重试）", errorMsg];
    }

    if (error) {
        *error = [NSError errorWithDomain:@"TrollShot"
                                     code:3002
                                 userInfo:@{NSLocalizedDescriptionKey : errorMsg}];
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
    /* 越狱环境：daemon 以 root 运行，App（mobile 用户）无权 kill root 进程
     * 也无权 unload 系统级 launchd plist。通过 HTTP /shutdown 请求让 daemon
     * 自行卸载 launchd 并退出。 */
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSystemPlistPath]) {
        /* 幂等：检测不到运行（可能本就停止，或已切到新端口）直接视为停止成功，
         * 避免误报"无法停止服务" */
        if (![self isDaemonRunning]) {
            [[NSFileManager defaultManager] removeItemAtPath:[self pidFilePath] error:nil];
            return YES;
        }
        if ([self sendShutdownRequest]) {
            /* 等待 daemon 自行关闭（最多 3 秒） */
            for (int i = 0; i < 30; i++) {
                if (![self isDaemonRunning]) {
                    [[NSFileManager defaultManager] removeItemAtPath:[self pidFilePath] error:nil];
                    return YES;
                }
                [NSThread sleepForTimeInterval:0.1];
            }
        }
        /* HTTP /stop 请求发送成功后，daemon 会写入 /var/mobile/trollshot/stop.flag 并退出，
         * wrapper 脚本检测到标志后不会重启。等待 daemon 退出即可。 */
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3003
                                     userInfo:@{NSLocalizedDescriptionKey : @"无法停止服务，请稍后重试"}];
        }
        return NO;
    }

    /* TrollStore 环境：直接 kill（daemon 以当前用户权限运行） */
    pid_t pid = [self readSavedPid];
    if (pid > 0 && kill(pid, 0) == 0) {
        kill(pid, SIGTERM);
        if (![self waitForProcessExit:pid timeout:1.0]) {
            kill(pid, SIGKILL);
            [self waitForProcessExit:pid timeout:0.5];
        }
    }

    [self killDaemonProcesses];
    [NSThread sleepForTimeInterval:0.2];
    [[NSFileManager defaultManager] removeItemAtPath:[self pidFilePath] error:nil];

    if ([self isDaemonRunning]) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3003
                                     userInfo:@{NSLocalizedDescriptionKey : @"无法停止服务，请稍后重试"}];
        }
        return NO;
    }
    return YES;
}

/* 发送 HTTP /stop 请求到 daemon，让 daemon 写入停止标志并退出（不卸载 launchd） */
- (BOOL)sendShutdownRequest {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return NO;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((int)[TrollShotManager apiPort]);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    /* 设置 2 秒超时，避免 daemon 无响应时卡住 */
    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        return NO;
    }

    const char *req = "GET /stop HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    ssize_t sent = send(sockfd, req, strlen(req), 0);
    if (sent <= 0) {
        close(sockfd);
        return NO;
    }

    /* 读取响应（确认 daemon 收到了请求） */
    char buf[256];
    recv(sockfd, buf, sizeof(buf) - 1, 0);
    close(sockfd);

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

/* 尝试 launchctl unload / bootout，同时检查系统路径和用户路径 */
- (void)spawnLaunchctlUnload {
    /* 系统级 plist（.deb 安装到越狱设备时在此路径） */
    if ([[NSFileManager defaultManager] fileExistsAtPath:kSystemPlistPath]) {
        /* 先尝试 bootout（iOS 14+ 新语法） */
        [self spawnCommand:@"/bin/launchctl" arguments:@[@"bootout", @"system/com.hogan.trollshot"]];
        /* 再尝试 unload（旧语法，兜底） */
        [self spawnCommand:@"/bin/launchctl" arguments:@[@"unload", @"-w", kSystemPlistPath]];
    }
    /* 用户级 plist（App 手动复制到 /var/mobile/trollshot/ 的情况） */
    NSString *userPlist = [self installedPlistPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:userPlist]) {
        [self spawnCommand:@"/bin/launchctl" arguments:@[@"unload", @"-w", userPlist]];
    }
}

/* 兜底结束 trollshotd 进程：HTTP /shutdown -> kill PID -> killall 三重清理 */
- (BOOL)killDaemonProcesses {
    NSLog(@"[TrollShot] 开始清理旧 daemon 进程...");

    /* 1. 尝试 HTTP /shutdown（新版 daemon 支持） */
    if ([self sendShutdownRequest]) {
        NSLog(@"[TrollShot] HTTP /shutdown 已发送，等待旧 daemon 退出...");
        [NSThread sleepForTimeInterval:1.0];
    }

    /* 2. 按 PID 文件直接 kill */
    pid_t pid = [self readSavedPid];
    if (pid > 0) {
        NSLog(@"[TrollShot] 从 PID 文件读取到 pid=%d，发送 SIGKILL", pid);
        kill(pid, SIGKILL);
        [NSThread sleepForTimeInterval:0.3];
    }

    /* 3. killall 兜底（尝试多个路径） */
    int ret1 = [self spawnCommand:@"/usr/bin/killall" arguments:@[@"-9", kDaemonName]];
    NSLog(@"[TrollShot] /usr/bin/killall -9 返回 %d", ret1);
    if (ret1 != 0) {
        int ret2 = [self spawnCommand:@"/bin/killall" arguments:@[@"-9", kDaemonName]];
        NSLog(@"[TrollShot] /bin/killall -9 返回 %d", ret2);
    }

    /* 4. 等待端口释放 */
    [NSThread sleepForTimeInterval:0.5];

    /* 5. 验证端口是否已释放 */
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd >= 0) {
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((int)[TrollShotManager apiPort]);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int canConnect = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
        close(sockfd);
        if (canConnect == 0) {
            NSLog(@"[TrollShot] 警告：端口 %d 仍被占用！", (int)[TrollShotManager apiPort]);
            return NO;
        }
        NSLog(@"[TrollShot] 端口 %d 已释放", (int)[TrollShotManager apiPort]);
    }
    return YES;
}

/* 卸载 daemon */
- (BOOL)uninstallDaemon:(NSError **)error {
    [self stopDaemon:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self installedDaemonPath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self installedPlistPath] error:nil];
    return YES;
}

@end
