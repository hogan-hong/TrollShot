/*
 This file is part of TrollShot, derived from TrollVNC.
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TrollShotManager.h"

#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#define kDaemonName        @"trollshotd"
#define kLaunchdPlistName  @"com.hogan.trollshot.plist"
#define kDaemonDestDir     @"/usr/local/bin"
#define kLaunchdDestDir    @"/Library/LaunchDaemons"
#define kLogDir            @"/var/log/trollshot"

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

/* 判断 daemon 是否正在运行，通过 launchctl list */
- (BOOL)isDaemonRunning {
    NSString *domain = @"system";
    NSString *service = @"com.hogan.trollshot";

    NSPipe *pipe = [NSPipe pipe];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/launchctl";
    task.arguments = @[@"list", service];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return NO;
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [output containsString:service];
}

/* 运行需要 root 权限的命令，通过 helper 方式用 launchctl 启动时会自动提权 */
- (BOOL)runCommandWithArguments:(NSArray<NSString *> *)arguments
                          error:(NSError **)error {
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = arguments.firstObject;
    task.arguments = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"启动命令失败: %@", e.reason]}];
        }
        return NO;
    }

    if (task.terminationStatus != 0) {
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (error) {
            *error = [NSError errorWithDomain:@"TrollShot"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey : errStr ?: @"未知错误"}];
        }
        return NO;
    }

    return YES;
}

/* 创建日志目录 */
- (BOOL)ensureLogDirectory:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:kLogDir isDirectory:&isDir]) {
        return [fm createDirectoryAtPath:kLogDir
             withIntermediateDirectories:YES
                              attributes:@{NSFileOwnerAccountName : @"root",
                                           NSFileGroupOwnerAccountName : @"wheel"}
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

    /* 复制可执行文件 */
    NSError *copyErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:[self installedDaemonPath] error:nil];
    if (![[NSFileManager defaultManager] copyItemAtPath:srcBin
                                                 toPath:[self installedDaemonPath]
                                                  error:&copyErr]) {
        if (error) *error = copyErr;
        return NO;
    }

    /* 设置可执行权限 */
    chmod([[self installedDaemonPath] fileSystemRepresentation], 0755);

    /* 复制 plist */
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

    return [self runCommandWithArguments:@[@"/bin/launchctl", @"load", @"-w", [self installedPlistPath]] error:error];
}

/* 停止 daemon */
- (BOOL)stopDaemon:(NSError **)error {
    return [self runCommandWithArguments:@[@"/bin/launchctl", @"unload", @"-w", [self installedPlistPath]] error:error];
}

/* 卸载 daemon */
- (BOOL)uninstallDaemon:(NSError **)error {
    [self stopDaemon:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self installedDaemonPath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self installedPlistPath] error:nil];
    return YES;
}

@end
