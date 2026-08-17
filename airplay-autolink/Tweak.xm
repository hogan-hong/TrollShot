// airplay-autolink Tweak -- 注入 SpringBoard 的 AirPlay 屏幕镜像自动连接守护
// 背景：CLI 进程里 sharedSystemScreenContext 恒 nil / 发现层不推送（门禁按宿主进程判定），
// 控制中心本体就在 SpringBoard 里跑这套 API，故注入 SB 执行三步链路：
//   MRAVRoutingDiscoverySession(features=2,mode=2) -> availableOutputDevices 匹配目标
//   -> [MRAVOutputContext sharedSystemScreenContext] setOutputDevices
// v6.7: 实验结论落地：关键参数 discoveryMode=2（mode=1 不激活扫描恒 0 台）；
//       单会话 features=2 + mode=2（f=2 干净命中屏幕镜像设备，f=1 会混入音频设备）；
//       防重复连接：setOutputDevices 后 15 秒内不补枪（6 秒窗口太短曾导致连发两次+掉线）；
//       40 秒扫不到目标重建发现会话。
// v6.8: 空闲态零轮询改造（事件驱动）：
//       KVO 被动监听 sharedSystemScreenContext.outputDevices，镜像断开瞬间系统回调触发
//       重连（检测延迟从最长一个轮询周期降到秒级）；空闲期不再每 25 秒拉一次属性。
//       保留低频兜底轮询（fallback，默认 120 秒一次）防 KVO 在私有实现上不触发。
//       扫描态逻辑沿用 v6.7。所有状态变更统一走 g_q 串行队列，KVO/轮询双源无竞争。
// v6.8.1 修订（实机发现两问题）：
//       ① 会话拆除过早：v6.8 初版 KVO 秒级确认镜像后立刻销毁发现会话，实测镜像
//          建立 2 秒后被系统清除（协商未完成时拆会话掐断路由）；改为确认后延迟
//          10 秒且仍处于镜像态才拆。v6.7 稳定是因为拆会话发生在发起后 8 秒。
//       ② 扫描链增殖：KVO 在协商期闪断（空->有->空），旧链尚挂起时 g_scanActive
//          被复位又开新链，同秒出现 7 个 tick；改为单链不变量--只有扫描链自己
//          能终结自己（stateCheck 不再复位 g_scanActive）。
// v7.0 整合进 TrollShot（2026-08-17）：
//       ① 断开清理上报：检测到镜像断开（含设备重启后的初始断开）时，自动向
//          uxplay 服务器（通过 Bonjour 按目标名解析 _airplay._tcp）发送
//          GET /cleanup?name=<本机设备名>，服务器立即清除本设备的半死残留会话
//          （否则约 6 分钟超时期间重连一直被干扰）。每断开剧集一次 + 30 秒限频。
//       ② 配置热加载：每次断开转变时重读 plist，TrollShot App 界面改"AirPlay
//          服务器名"即时生效，无需重启 SpringBoard。
//       配置改由 TrollShot App 主界面写入（也可手工维护）。
// 配置：/var/mobile/Library/Preferences/com.hoganhong.airplay-autolink.plist
//   target    目标设备名（默认 TrollShot，包含匹配）
//   interval  上下文缺失时重试间隔秒（默认 25）
//   fallback  空闲态兜底轮询间隔秒（默认 120，最小 30）
// 日志：/var/mobile/Library/Logs/airplay-autolink.log
#import <Foundation/Foundation.h>
#import <UIKit/UIDevice.h>

@class MRAVOutputDevice, MRAVOutputContext, MRAVRoutingDiscoverySession;

@interface MRAVOutputDevice : NSObject
@property (readonly) NSString *name;
@property (readonly) NSString *uid;
@end

@interface MRAVOutputContext : NSObject
@property (readonly) NSArray<MRAVOutputDevice *> *outputDevices;
- (void)setOutputDevices:(NSArray<MRAVOutputDevice *> *)devices
                initiator:(NSString *)initiator
        withCallbackQueue:(dispatch_queue_t)queue
                    block:(void (^)(NSError *error))block;
+ (instancetype)sharedSystemScreenContext;
@end

@interface MRAVRoutingDiscoverySession : NSObject
@property (readonly) NSArray<MRAVOutputDevice *> *availableOutputDevices;
- (void)setDiscoveryMode:(NSUInteger)mode;
- (id)addOutputDevicesAddedCallback:(void (^)(NSArray<MRAVOutputDevice *> *added))block;
+ (instancetype)discoverySessionWithEndpointFeatures:(NSUInteger)features;
@end

static NSString *g_target = @"TrollShot";
static NSTimeInterval g_interval = 25.0;    // 上下文缺失重试间隔
static NSTimeInterval g_fallback = 120.0;   // 空闲态兜底轮询间隔
static MRAVRoutingDiscoverySession *g_sess = nil;
static int g_scanTicks = 0;
static int g_tickSeq = 0;
static NSTimeInterval g_lastFire = 0;   // 上次 setOutputDevices 发起时刻，防 15 秒内重复补枪
static NSString *g_step = @"ctor";      // 看门狗用：记录当前执行到哪一步
static dispatch_queue_t g_q;            // 串行队列：tick / KVO / 兜底轮询全在此汇合
static BOOL g_mirroring = NO;           // 当前认知状态：是否镜像中
static BOOL g_scanActive = NO;          // 扫描循环是否在跑
static NSObject *g_kvoObserver = nil;   // KVO 观察者载体
static int g_fbCount = 0;               // 兜底轮询计数（心跳日志用）
static BOOL g_stateKnown = NO;          // 是否已判定过初始状态（重启后首判即断开也算断开转变）
static NSTimeInterval g_lastCleanup = 0; // 上次清理上报时刻（30 秒限频）

static void alog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[airplay-autolink] %@", msg);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSString *path = @"/var/mobile/Library/Logs/airplay-autolink.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [[NSFileManager defaultManager] setAttributes:@{NSFileOwnerAccountID: @(501)}
                                             ofItemAtPath:path error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static void later(NSTimeInterval sec, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                   g_q, block);
}

static void loadPrefs(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.hoganhong.airplay-autolink.plist"];
    if ([p isKindOfClass:[NSDictionary class]]) {
        if ([p[@"target"] isKindOfClass:[NSString class]]) g_target = p[@"target"];
        if ([p[@"interval"] doubleValue] >= 5) g_interval = [p[@"interval"] doubleValue];
        if ([p[@"fallback"] doubleValue] >= 30) g_fallback = [p[@"fallback"] doubleValue];
    }
}

static void stateCheck(NSString *src);
static void scanTick(void);
static void cleanupOnDisconnect(void);

// 镜像确认后延迟 10 秒再拆发现会话：连接协商需数秒，协商中拆会话会掐断路由
// （v6.8 初版实测：KVO 秒级确认后立即拆会话，镜像建立 2 秒后被系统清除）。
// 若 10 秒内又断开（g_mirroring=NO / 扫描链复活），会话保留给重连复用。
static void teardownSessionSoon(void) {
    later(10, ^{
        if (g_mirroring && !g_scanActive) {
            g_sess = nil;
        }
    });
}

// 看门狗：15 秒后若 g_step 没变，说明卡死在某个 XPC 调用上，把它报出来
static void armWatchdog(int seq) {
    NSString *stepAtArm = g_step;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(0, 0), ^{
        if (g_tickSeq == seq && [g_step isEqualToString:stepAtArm]) {
            alog(@"⏰ 看门狗: tick#%d 卡死在 [%@] 超过 15 秒", seq, stepAtArm);
        }
    });
}

// 状态分派（只在实际调用时判一次 outputDevices）：
//   非空 -> 镜像中：停扫描、销毁发现会话，静默等待下一次 KVO/兜底
//   空   -> 断开：若扫描未在跑则立即启动重连扫描
static void stateCheck(NSString *src) {
    MRAVOutputContext *ctx = [MRAVOutputContext sharedSystemScreenContext];
    if (!ctx) {
        alog(@"[%@] 屏幕上下文 nil，%.0fs 后重试", src, g_interval);
        later(g_interval, ^{ stateCheck(@"重试"); });
        return;
    }
    if (ctx.outputDevices.count) {
        if (!g_mirroring) {
            MRAVOutputDevice *d = ctx.outputDevices.firstObject;
            alog(@"✅ %@ 确认镜像进行中: %@ (%@)", src, d.name, d.uid);
            teardownSessionSoon();
        }
        g_mirroring = YES;
        g_stateKnown = YES;
        g_scanTicks = 0;
        // 注意：这里不动 g_scanActive--若还有挂起的扫描链，让它在下一拍自检时
        // 自行退出（单链不变量）。否则 KVO 协商期闪断（空->有->空）会在旧链
        // 尚挂起时再开新链，造成扫描链增殖（v6.8 初版实测同秒 7 个 tick）。
        return;
    }
    // 断开转变（镜像中->断开，或重启后首次判定即断开）：
    // 先热加载配置（App 界面改名即时生效），再向服务器上报清理本设备残留会话
    if (g_mirroring || !g_stateKnown) {
        if (g_mirroring) {
            alog(@"⚡ %@ 报告镜像断开，被动触发重连 target=%@", src, g_target);
        }
        loadPrefs();
        cleanupOnDisconnect();
    }
    g_mirroring = NO;
    g_stateKnown = YES;
    if (!g_scanActive) scanTick();
}

// 扫描循环（只在断开后运行，1 秒一拍；镜像确认后自动停）
static void scanTick(void) {
    @autoreleasepool {
        g_scanActive = YES;
        if (g_mirroring) { g_scanActive = NO; return; }  // 期间 KVO 已确认恢复
        int seq = ++g_tickSeq;
        g_step = @"tick入口";
        armWatchdog(seq);

        g_step = @"sharedSystemScreenContext";
        MRAVOutputContext *ctx = [MRAVOutputContext sharedSystemScreenContext];
        if (!ctx) {
            alog(@"tick#%d 屏幕上下文 nil，%.0fs 后重试", seq, g_interval);
            g_step = @"等待重试";
            later(g_interval, ^{ scanTick(); });
            return;
        }
        // 镜像已恢复（本拍自检）：停扫描回到空闲态
        if (ctx.outputDevices.count) {
            MRAVOutputDevice *d = ctx.outputDevices.firstObject;
            alog(@"tick#%d 自检发现镜像已恢复: %@ (%@)，扫描停止", seq, d.name, d.uid);
            g_mirroring = YES;
            teardownSessionSoon();
            g_scanActive = NO;   // 本链到此终结（单链不变量：只有链自己能复位）
            return;
        }

        // 断开态：扫描发现层找目标
        // 关键参数（v6.7 实验定论）：discoveryMode=2 才激活扫描（mode=1 恒 0 台）；
        // features=2 干净命中屏幕镜像设备（features=1 会混入纯音频设备如"扬声器"）
        if (!g_sess) {
            g_step = @"创建发现会话";
            g_sess = [MRAVRoutingDiscoverySession discoverySessionWithEndpointFeatures:2];
            g_step = @"setDiscoveryMode";
            [g_sess setDiscoveryMode:2];
            [g_sess addOutputDevicesAddedCallback:^(NSArray *added) {
                if (![added count]) return;   // 会话拆除时的空推送，忽略
                NSMutableArray *names = [NSMutableArray array];
                for (MRAVOutputDevice *d in added) [names addObject:d.name ?: @"?"];
                alog(@"🎉 推送新增 %lu 台: %@", (unsigned long)added.count,
                     [names componentsJoinedByString:@","]);
            }];
            g_scanTicks = 0;
            alog(@"tick#%d 发现会话已建(features=2,mode=2)扫描 target=%@", seq, g_target);
        }
        g_step = @"读取availableOutputDevices";
        NSArray *devs = g_sess.availableOutputDevices;
        for (MRAVOutputDevice *d in devs) {
            if ([d.name.lowercaseString containsString:g_target.lowercaseString]) {
                // 防补枪：上次发起未满 15 秒且仍未见镜像 = 连接仍在协商，稍候再查，不重发
                if ([NSDate date].timeIntervalSince1970 - g_lastFire < 15) {
                    alog(@"tick#%d 命中 %@ 但距上次发起<15s，等待协商完成", seq, d.name);
                    g_step = @"等待协商";
                    later(5, ^{ scanTick(); });
                    return;
                }
                alog(@"tick#%d 命中 %@ (%@)，建立镜像...", seq, d.name, d.uid);
                g_step = @"setOutputDevices";
                g_lastFire = [NSDate date].timeIntervalSince1970;
                [ctx setOutputDevices:@[d] initiator:@"airplay-autolink"
                      withCallbackQueue:g_q
                                    block:^(NSError *error) {
                    alog(error ? @"❌ setOutputDevices: %@" : @"✅ setOutputDevices 成功", error ?: @"");
                }];
                g_step = @"验证镜像";
                later(8, ^{ scanTick(); });  // 8 秒后验证（期间 KVO 也会先报）
                return;
            }
        }
        alog(@"tick#%d 发现层: %lu 台设备", seq, (unsigned long)devs.count);
        // 40 秒扫不到就重建会话（防会话僵死）
        if (++g_scanTicks > 40) {
            g_sess = nil;
            alog(@"tick#%d 40 秒未发现目标，重建会话", seq);
        }
        g_step = @"扫描间隔";
        later(1, ^{ scanTick(); });
    }
}

// ============ 断开清理上报（v7.0 整合） ============
// 设备异常重启后 uxplay 服务器残留本设备的半死会话（约 6 分钟超时），期间重连被干扰。
// 断开转变时通过 Bonjour 按目标服务名解析 _airplay._tcp 得到服务器地址，
// 异步 GET /cleanup?name=<本机设备名>，服务器立即清除本设备全部残留连接。
// fire-and-forget：失败不影响正常重连流程（服务器超时后自愈）。30 秒限频防闪断风暴刷接口。

@interface AACleanupResolver : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (copy) NSString *target;
@property (strong) NSNetServiceBrowser *browser;
@property (strong) NSNetService *service;
@property (copy) void (^onSuccess)(void);
@property (copy) void (^onFailure)(void);
@property (assign) BOOL finished;
+ (void)resolveTarget:(NSString *)target onSuccess:(void (^)(void))onSuccess onFailure:(void (^)(void))onFailure;
- (void)stopAll;
@end

@implementation AACleanupResolver

+ (void)resolveTarget:(NSString *)target onSuccess:(void (^)(void))onSuccess onFailure:(void (^)(void))onFailure {
    AACleanupResolver *r = [[self alloc] init];
    r.target = target;
    r.onSuccess = onSuccess;
    r.onFailure = onFailure;
    r.browser = [[NSNetServiceBrowser alloc] init];
    r.browser.delegate = r;
    // 主 runloop 调度：SB 主线程常驻，回调全部异步不阻塞
    [r.browser scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [r.browser searchForServicesOfType:@"_airplay._tcp." inDomain:@"local."];
    // 4 秒兜底自毁（dispatch_after 捕获 r 延长其生命周期到此刻）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (!r.finished) { [r stopAll]; [r reportFailure:@"Bonjour 超时"]; }
    });
}

- (void)reportSuccess {
    if (self.finished) return;
    self.finished = YES;
    if (self.onSuccess) self.onSuccess();
}

- (void)reportFailure:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;
    if (self.onFailure) self.onFailure();
    (void)reason;  // 原因已在各调用点打日志
}

- (void)stopAll {
    [self.browser stop];
    self.browser.delegate = nil;
    self.browser = nil;
    [self.service stop];
    self.service.delegate = nil;
    self.service = nil;
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    // 与镜像发现同一包含匹配规则（服务名含 target 即命中）
    if (self.service) return;
    NSString *n = service.name ?: @"";
    if (![n.lowercaseString containsString:self.target.lowercaseString]) return;
    self.service = service;
    service.delegate = self;
    [service resolveWithTimeout:3];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    NSString *host = sender.hostName;
    NSInteger port = sender.port;
    [self stopAll];
    if (!host || port <= 0) {
        alog(@"🧹 Bonjour 解析完成但地址无效，跳过清理上报");
        [self reportFailure:@"地址无效"];
        return;
    }
    NSString *selfName = [UIDevice currentDevice].name ?: @"unknown";
    NSString *encoded = [selfName stringByAddingPercentEncodingWithAllowedCharacters:
                                    [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%ld/cleanup?name=%@",
                        host, (long)port, encoded ?: selfName];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        alog(@"🧹 清理上报 URL 构造失败，跳过");
        [self reportFailure:@"URL 构造失败"];
        return;
    }
    alog(@"🧹 清理上报: %@（本机名=%@）", urlStr, selfName);
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 4;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    [[sess dataTaskWithURL:url completionHandler:
        ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            alog(@"🧹 清理上报失败（不影响重连）: %@", err.localizedDescription);
            [self reportFailure:err.localizedDescription];
            return;
        }
        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        alog(@"🧹 清理上报完成: HTTP %ld %@",
             (long)((NSHTTPURLResponse *)resp).statusCode,
             [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        [self reportSuccess];
    }] resume];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict {
    alog(@"🧹 Bonjour 服务解析失败: %@（跳过清理上报）", sender.name);
    [self stopAll];
    [self reportFailure:@"服务解析失败"];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict {
    alog(@"🧹 Bonjour 搜索失败（跳过清理上报）: %@", errorDict);
    [self stopAll];
    [self reportFailure:@"搜索失败"];
}

@end

// 断开转变点入口：限频后转到主队列解析上报（从 g_q 调用）。
// 连续失败退避：3 次失败后暂停 10 分钟再试（实测 iOS 14 SB 内 Bonjour 浏览
// 受本地网络权限限制恒失败 -72008；同名顶替自清理已兜底，上报只是加速通道）
static void cleanupOnDisconnect(void) {
    static int failCount = 0;
    static NSTimeInterval lastFailTs = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - g_lastCleanup < 30) return;
    if (failCount >= 3 && now - lastFailTs < 600) return;
    g_lastCleanup = now;
    NSString *target = [g_target copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [AACleanupResolver resolveTarget:target onSuccess:^{
            failCount = 0;
        } onFailure:^{
            if (++failCount == 1) {
                alog(@"🧹 清理上报不可用（Bonjour 受限），改由服务器同名顶替兜底，10 分钟后重试");
            }
            lastFailTs = [NSDate date].timeIntervalSince1970;
        }];
    });
}

// KVO 观察者：outputDevices 一变（断开清空/连接填充）立即投递到 g_q 判态
@interface AAObserver : NSObject
@end

@implementation AAObserver
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                        change:(NSDictionary *)ch context:(void *)cx {
    if (cx != (void *)1) { [super observeValueForKeyPath:kp ofObject:obj change:ch context:cx]; return; }
    dispatch_async(g_q, ^{ @autoreleasepool { stateCheck(@"KVO"); } });
}
@end

static void setupKVO(void) {
    MRAVOutputContext *ctx = [MRAVOutputContext sharedSystemScreenContext];
    if (!ctx) { alog(@"KVO 挂载失败：上下文 nil，仅靠兜底轮询"); return; }
    g_kvoObserver = [[AAObserver alloc] init];
    @try {
        [ctx addObserver:g_kvoObserver forKeyPath:@"outputDevices"
                  options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                  context:(void *)1];
        alog(@"KVO 监听已挂载 outputDevices（断开秒级感知）");
    } @catch (NSException *e) {
        g_kvoObserver = nil;
        alog(@"KVO 挂载异常: %@，仅靠兜底轮询(%.0fs)", e, g_fallback);
    }
}

// 兜底轮询：低频自检，防 KVO 在私有实现上不触发；空闲稳定期不打日志，每 30 拍一条心跳
static void fallbackLoop(void) {
    later(g_fallback, ^{
        g_fbCount++;
        if (g_fbCount % 30 == 0 && g_mirroring) {
            alog(@"心跳: 守护运行中，镜像进行中(兜底轮询第 %d 拍)", g_fbCount);
        }
        stateCheck(@"兜底轮询");
        fallbackLoop();
    });
}

%ctor {
    @autoreleasepool {
        g_q = dispatch_queue_create("com.hoganhong.airlink", DISPATCH_QUEUE_SERIAL);
        loadPrefs();
        alog(@"已加载 v7.0（整合进 TrollShot：事件驱动+兜底轮询 %.0fs+断开清理上报）target=%@",
             g_fallback, g_target);
        // 等 SpringBoard 完全起来再开工（后台队列，不碰主线程）
        later(20, ^{
            setupKVO();
            stateCheck(@"启动");
            fallbackLoop();
        });
    }
}
