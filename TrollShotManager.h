/*
 This file is part of TrollShot, derived from TrollVNC.
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* TrollShot 后台 daemon 管理类 */
@interface TrollShotManager : NSObject

+ (instancetype)sharedManager;

/* daemon 是否已安装到用户可写目录 */
@property (nonatomic, readonly) BOOL isDaemonInstalled;

/* daemon 是否正在运行 */
@property (nonatomic, readonly) BOOL isDaemonRunning;

/* 调试模式标志读写（持久化到 /var/mobile/trollshot/debug_mode） */
+ (BOOL)isDebugMode;
+ (void)setDebugMode:(BOOL)enabled;

/* 清空日志文件 */
+ (void)clearLogFile;

/* 将 IPA 中的 daemon 安装到 /var/mobile/trollshot/ */
- (BOOL)installDaemon:(NSError **)error;

/* 直接启动 daemon 进程 */
- (BOOL)startDaemon:(NSError **)error;

/* 停止 daemon 进程 */
- (BOOL)stopDaemon:(NSError **)error;

/* 卸载 daemon 和 plist */
- (BOOL)uninstallDaemon:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
