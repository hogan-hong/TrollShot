/*
 This file is part of TrollShot.
 Copyright (c) 2026 TrollShot contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.
*/

#import "AppDelegate.h"
#import "TrollShotManager.h"

#import <arpa/inet.h>
#import <ifaddrs.h>

@interface AppDelegate ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor blackColor];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, rootVC.view.bounds.size.width - 40, 80)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleLabel.text = @"TrollShot\n屏幕截图服务";
    [rootVC.view addSubview:titleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 180, rootVC.view.bounds.size.width - 40, 80)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:16];
    [rootVC.view addSubview:self.statusLabel];

    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.frame = CGRectMake(40, 300, rootVC.view.bounds.size.width - 80, 50);
    self.toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.toggleButton.backgroundColor = [UIColor darkGrayColor];
    self.toggleButton.layer.cornerRadius = 8;
    [self.toggleButton addTarget:self action:@selector(toggleService:) forControlEvents:UIControlEventTouchUpInside];
    [rootVC.view addSubview:self.toggleButton];

    self.window.rootViewController = rootVC;
    [self.window makeKeyAndVisible];

    [self refreshUI];

    /* 每 2 秒自动刷新状态 */
    [NSTimer scheduledTimerWithTimeInterval:2.0
                                     target:self
                                   selector:@selector(refreshUI)
                                   userInfo:nil
                                    repeats:YES];

    return YES;
}

- (void)refreshUI {
    TrollShotManager *mgr = [TrollShotManager sharedManager];
    BOOL running = mgr.isDaemonRunning;

    if (running) {
        NSString *ip = [self localIPAddress];
        self.statusLabel.text = [NSString stringWithFormat:@"服务状态：运行中\n访问 http://%@:8080/screenshot", ip];
        [self.toggleButton setTitle:@"停止服务" forState:UIControlStateNormal];
    } else {
        self.statusLabel.text = @"服务状态：已停止\n点击下方按钮启动";
        [self.toggleButton setTitle:@"启动服务" forState:UIControlStateNormal];
    }
}

/* 获取当前 WiFi IP，用于界面提示 */
- (NSString *)localIPAddress {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *ip = nil;

    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name isEqualToString:@"en0"]) {
                    ip = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return ip ?: @"<本机IP>";
}

- (void)toggleService:(UIButton *)sender {
    TrollShotManager *mgr = [TrollShotManager sharedManager];
    NSError *error = nil;
    BOOL ok = NO;

    if (mgr.isDaemonRunning) {
        ok = [mgr stopDaemon:&error];
    } else {
        ok = [mgr startDaemon:&error];
    }

    if (!ok) {
        NSString *msg = error.localizedDescription ?: @"操作失败";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
    }

    [self refreshUI];
}

@end
