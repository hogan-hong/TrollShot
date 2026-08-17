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

@interface AppDelegate () <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIButton *debugButton;
@property (nonatomic, strong) UITextField *portField;
@property (nonatomic, strong) UITextField *airplayField;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor blackColor];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, rootVC.view.bounds.size.width - 40, 70)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    /* 标题下带构建版本号（CI 注入 Info.plist，随 GitHub 构建号递增） */
    NSString *shortVer = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"1.0.0";
    titleLabel.text = [NSString stringWithFormat:@"TrollShot 屏幕截图服务\nv%@", shortVer];
    [rootVC.view addSubview:titleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 140, rootVC.view.bounds.size.width - 40, 70)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:16];
    [rootVC.view addSubview:self.statusLabel];

    /* 配置行：左侧标签 + 右侧输入框 */
    CGFloat cfgY[] = {225, 275};
    UILabel *portLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, cfgY[0], 130, 34)];
    portLabel.text = @"API 端口：";
    portLabel.textColor = [UIColor whiteColor];
    portLabel.font = [UIFont systemFontOfSize:15];
    portLabel.textAlignment = NSTextAlignmentRight;
    [rootVC.view addSubview:portLabel];

    self.portField = [[UITextField alloc] initWithFrame:CGRectMake(160, cfgY[0], rootVC.view.bounds.size.width - 180, 34)];
    self.portField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.portField.delegate = self;
    self.portField.tag = 1;
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.portField.textColor = [UIColor whiteColor];
    self.portField.font = [UIFont systemFontOfSize:15];
    self.portField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.portField.layer.cornerRadius = 6;
    self.portField.textAlignment = NSTextAlignmentCenter;
    self.portField.text = [NSString stringWithFormat:@"%ld", (long)[TrollShotManager apiPort]];
    self.portField.placeholder = @"6688";
    [rootVC.view addSubview:self.portField];

    UILabel *airplayLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, cfgY[1], 130, 34)];
    airplayLabel.text = @"AirPlay服务器：";
    airplayLabel.textColor = [UIColor whiteColor];
    airplayLabel.font = [UIFont systemFontOfSize:15];
    airplayLabel.adjustsFontSizeToFitWidth = YES;
    airplayLabel.textAlignment = NSTextAlignmentRight;
    [rootVC.view addSubview:airplayLabel];

    self.airplayField = [[UITextField alloc] initWithFrame:CGRectMake(160, cfgY[1], rootVC.view.bounds.size.width - 180, 34)];
    self.airplayField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.airplayField.delegate = self;
    self.airplayField.tag = 2;
    self.airplayField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.airplayField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.airplayField.textColor = [UIColor whiteColor];
    self.airplayField.font = [UIFont systemFontOfSize:15];
    self.airplayField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    self.airplayField.layer.cornerRadius = 6;
    self.airplayField.textAlignment = NSTextAlignmentCenter;
    self.airplayField.text = [TrollShotManager airplayServerName];
    self.airplayField.placeholder = @"TrollShot";
    [rootVC.view addSubview:self.airplayField];

    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.frame = CGRectMake(40, 335, rootVC.view.bounds.size.width - 80, 50);
    self.toggleButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.toggleButton.backgroundColor = [UIColor darkGrayColor];
    self.toggleButton.layer.cornerRadius = 8;
    [self.toggleButton addTarget:self action:@selector(toggleService:) forControlEvents:UIControlEventTouchUpInside];
    [rootVC.view addSubview:self.toggleButton];

    /* 调试模式按钮 */
    self.debugButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.debugButton.frame = CGRectMake(40, 395, rootVC.view.bounds.size.width - 80, 44);
    self.debugButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.debugButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.debugButton.titleLabel.font = [UIFont systemFontOfSize:16];
    self.debugButton.layer.cornerRadius = 8;
    self.debugButton.layer.borderWidth = 1;
    self.debugButton.layer.borderColor = [UIColor grayColor].CGColor;
    [self.debugButton addTarget:self action:@selector(toggleDebugMode:) forControlEvents:UIControlEventTouchUpInside];
    [rootVC.view addSubview:self.debugButton];

    /* 点击空白处收起键盘并保存 */
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [rootVC.view addGestureRecognizer:tap];

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
    BOOL debug = [TrollShotManager isDebugMode];
    NSInteger port = [TrollShotManager apiPort];

    if (running) {
        NSString *ip = [self localIPAddress];
        self.statusLabel.text = [NSString stringWithFormat:@"服务状态：运行中\n访问 http://%@:%ld/screenshot", ip, (long)port];
        [self.toggleButton setTitle:@"停止服务" forState:UIControlStateNormal];
    } else {
        self.statusLabel.text = @"服务状态：已停止\n点击下方按钮启动";
        [self.toggleButton setTitle:@"启动服务" forState:UIControlStateNormal];
    }

    /* 调试模式按钮状态 */
    if (debug) {
        [self.debugButton setTitle:@"调试模式：开启（点击关闭）" forState:UIControlStateNormal];
        self.debugButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:0.8];
    } else {
        [self.debugButton setTitle:@"调试模式：关闭（点击开启）" forState:UIControlStateNormal];
        self.debugButton.backgroundColor = [UIColor clearColor];
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

- (void)toggleDebugMode:(UIButton *)sender {
    BOOL currentDebug = [TrollShotManager isDebugMode];
    BOOL newDebug = !currentDebug;

    /* 开启调试模式时询问是否清空旧日志 */
    if (newDebug) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"开启调试模式"
                                                                       message:@"将开始记录运行日志。是否同时清空旧的日志文件？"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"开启并清空日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            BOOL ok = [TrollShotManager setDebugMode:YES];
            if (!ok) {
                [self showDebugWriteError];
                return;
            }
            [TrollShotManager clearLogFile];
            [self restartDaemonIfNeeded];
            [self refreshUI];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"开启（保留旧日志）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            BOOL ok = [TrollShotManager setDebugMode:YES];
            if (!ok) {
                [self showDebugWriteError];
                return;
            }
            [self restartDaemonIfNeeded];
            [self refreshUI];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
    } else {
        /* 关闭调试模式 */
        BOOL ok = [TrollShotManager setDebugMode:NO];
        if (!ok) {
            [self showDebugWriteError];
            return;
        }
        [self restartDaemonIfNeeded];
        [self refreshUI];
    }
}

/* 调试模式标志文件写入失败时弹出提示 */
- (void)showDebugWriteError {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法切换调试模式"
                                                                   message:@"写入 /var/mobile/trollshot/debug_mode 失败，可能是目录权限问题。请通过 SSH 手动创建目录：\nmkdir -p /var/mobile/trollshot\nchown mobile:mobile /var/mobile/trollshot"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

/* 调试模式切换后，如果 daemon 在运行则自动重启使设置生效 */
- (void)restartDaemonIfNeeded {
    TrollShotManager *mgr = [TrollShotManager sharedManager];
    if (mgr.isDaemonRunning) {
        [mgr stopDaemon:nil];
        [NSThread sleepForTimeInterval:0.3];
        NSError *err = nil;
        if (![mgr startDaemon:&err]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重启失败"
                                                                           message:err.localizedDescription ?: @"未知错误"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
        }
    }
}

#pragma mark - 配置输入框

/* 点击空白收起键盘（触发 DidEndEditing 保存） */
- (void)dismissKeyboard {
    [self.portField resignFirstResponder];
    [self.airplayField resignFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

/* 编辑结束保存配置：
 * 端口 -> 写标志文件 + daemon 运行中自动重启生效
 * AirPlay 服务器名 -> 写 tweak plist，断开转变时热加载即时生效 */
- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField.tag == 1) {
        NSInteger port = textField.text.integerValue;
        if (port < 1 || port > 65535) {
            textField.text = [NSString stringWithFormat:@"%ld", (long)[TrollShotManager apiPort]];
            return;
        }
        if (port == [TrollShotManager apiPort]) return;
        if (![TrollShotManager setApiPort:port]) {
            textField.text = [NSString stringWithFormat:@"%ld", (long)[TrollShotManager apiPort]];
            return;
        }
        [self restartDaemonIfNeeded];
        [self refreshUI];
    } else if (textField.tag == 2) {
        NSString *name = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length == 0) {
            textField.text = [TrollShotManager airplayServerName];
            return;
        }
        if ([name isEqualToString:[TrollShotManager airplayServerName]]) return;
        if ([TrollShotManager setAirplayServerName:name]) {
            NSLog(@"[TrollShot] AirPlay 服务器名已保存: %@（tweak 断开转变时热加载生效）", name);
        } else {
            textField.text = [TrollShotManager airplayServerName];
        }
    }
}

@end
