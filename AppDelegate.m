/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "AppDelegate.h"
#import "HTTPScreenshotServer.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor blackColor];

    UILabel *label = [[UILabel alloc] initWithFrame:rootVC.view.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:18];
    label.text = @"TrollShot 运行中\n\nhttp://<本机IP>:8080/screenshot";
    [rootVC.view addSubview:label];

    self.window.rootViewController = rootVC;
    [self.window makeKeyAndVisible];

    /* 在后台线程启动截图 HTTP 服务器 */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        StartScreenshotServer(8080);
    });

    return YES;
}

@end
