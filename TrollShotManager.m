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
#import <spawn.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <unistd.h>

#define kDaemonName        @"trollshotd"
#define kLaunchdPlistName  @"com.hogan.trollshot.plist"
#define kDaemonDestDir     @"/usr/local/bin"
#define kLaunchdDestDir    @"/Library/LaunchDaemons"
#define kLogDir            @"/var/mobile/trollshot"

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

/* daemon 系统目标路径 */
- (NSString *)installedDaemonPath {
    return [kDaemonDestDir stringByAppendingPathComponent:kDaemonName];
}

/* plist 系统目标路径 */
- (NSString *)installedPlistPath {
    return [kLaunchdDestDir stringByAppendingPathComponent:kLaunchdPlistName];
}

/* 判断 daemon 是否已安装 */
- (BOOL)isDaemonInstalled {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:[self installedDaemonPath] isDirectory:&isDir] && !isDir;
}

/* 使用 posix_spawn 执行命令，返回子进程退出码 */
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

    if (ret != 0) {
        return -1;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

/* 判断 daemon 是否正在运行 */
- (BOOL)isDaemonRunning {
    int status = [self spawnCommand:@"/bin/launchctl" arguments:@[@"list", @"com.hogan.trollshot"]];
    return status == 0;
}

/* 创建日志目录 */
- (BOOL)ensureLogDirectory:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kLogDir isDirectory:&isDir]) {
        return [fm createDirectoryAtPath:kLogDir
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:error];
    }
    return YES;
}

/* 安装 daemon 到 /usr/local/bin */
- (BOOL)installDaemon:(NSError **)error {
    NSString *srcBin = [self bundledDaemonPath];
    NSString *srcPlist = [self bundledPlistPath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:srcBin]) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey : @"应用内未找到 trollshotd，请重新安装 IPA"}];
        }
        return NO;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:srcPlist]) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:2002
                                     userInfo:@{NSLocalizedDescriptionKey : @"应用内未找到 launchd plist，请重新安装 IPA"}];
        }
        return NO;
    }

    if (![self ensureLogDirectory:error]) return NO;

    NSError *copyErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:[self installedDaemonPath] error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:srcBin
                                                 toPath:[self installedDaemonPath]
                                                  error:&copyErr]) {
        if (error) *error = copyErr;
        return NO;
    }

    chmod([[self installedDaemonPath] fileSystemRepresentation], 0755);

    [[NSFileManager defaultManager] removeItemAtPath:[self installedPlistPath] error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:srcPlist
                                                 toPath:[self installedPlistPath]
                                                  error:&copyErr]) {
        if (error) *error = copyErr;
        return NO;
    }

    chmod([[self installedPlistPath] fileSystemRepresentation], 0644);

    return YES;
}

/* 启动 daemon */
- (BOOL)startDaemon:(NSError **)error {
    if (!self.isDaemonInstalled) {
        if (![self installDaemon:error]) return NO;
    }

    int status = [self spawnCommand:@"/bin/launchctl"
                          arguments:@[@"load", @"-w", [self installedPlistPath]]];
    if (status != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3001
                                     userInfo:@{NSLocalizedDescriptionKey : @"launchctl load 失败，请检查是否已越狱或 TrollStore 权限"}];
        }
        return NO;
    }
    return YES;
}

/* 停止 daemon */
- (BOOL)stopDaemon:(NSError **)error {
    int status = [self spawnCommand:@"/bin/launchctl"
                          arguments:@[@"unload", @"-w", [self installedPlistPath]]];
    if (status != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:3002
                                     userInfo:@{NSLocalizedDescriptionKey : @"launchctl unload 失败"}];
        }
        return NO;
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
