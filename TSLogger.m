/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "TSLogger.h"

@implementation TSLogger {
    NSString *_logPath;
    NSFileHandle *_fileHandle;
    NSDateFormatter *_formatter;
    dispatch_queue_t _queue;
}

+ (instancetype)sharedLogger {
    static TSLogger *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;

    _queue = dispatch_queue_create("com.trollshot.logger", DISPATCH_QUEUE_SERIAL);

    _formatter = [[NSDateFormatter alloc] init];
    _formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    _formatter.timeZone = [NSTimeZone localTimeZone];

    /* 优先写到 Documents，如果不可用则写到 tmp */
    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *baseDir = docPaths.firstObject ?: NSTemporaryDirectory();
    _logPath = [baseDir stringByAppendingPathComponent:@"TrollShot.log"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:_logPath]) {
        [[NSFileManager defaultManager] createFileAtPath:_logPath contents:nil attributes:nil];
    }
    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:_logPath];
    [_fileHandle seekToEndOfFile];

    return self;
}

- (void)log:(NSString *)message {
    if (!_debugEnabled) return;
    dispatch_async(_queue, ^{
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [self->_formatter stringFromDate:[NSDate date]], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        [self->_fileHandle writeData:data];
    });
}

- (NSString *)logPath {
    return _logPath;
}

@end
