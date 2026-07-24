/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 简单的文件日志，写入应用容器，方便抓取运行/崩溃信息 */
@interface TSLogger : NSObject

+ (instancetype)sharedLogger;

/* 调试模式开关，YES 时才写日志，默认 NO */
@property (nonatomic, assign) BOOL debugEnabled;

/* 记录一条日志（仅在 debugEnabled=YES 时写入） */
- (void)log:(NSString *)message;

/* 日志文件路径 */
- (NSString *)logPath;

@end

NS_ASSUME_NONNULL_END
