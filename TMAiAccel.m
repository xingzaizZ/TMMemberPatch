// TMAiAccel.m  —  通用广告加速 + 广告拦截一体插件
// 目标: TM手游加速器 com.TMSpeed.Lightning (2.1.8)
// 兼容: 内置 AWM 聚合 + GDT / 快手 / 穿山甲 / 百度 / Sigmob / Wind 广告的 App
//
// 参考实现: AdAccel.dylib (17 类 / 456 selector / 25 个 adaccel_ hook)
// 本版在其基础上补齐:
//   1. 百度 BaiduMobAdMediaPlayer / BaiduMobAdVideoView 速率
//   2. Wind  WindPlayerView / WindAVPlayerView / WindPlayerManager 速率
//   3. 自研 ZCVideoPlayer / SobotVideoPlayer / 快手 KS 速率
//   4. 全 SDK 开屏倒计时归零 + 开屏视图自动移除
//   5. 摇一摇/重力感应全量拦截（含 UIEventSubtypeMotionShake）
//   6. 点击跳转拦截（itms-apps / taobao / pinduoduo / kwai 等）
//   7. 悬浮球滑块，1x - 20x 可调

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - 配置键

static NSString * const kCfgEnabled    = @"com.tm.aiaccel.enabled";
static NSString * const kCfgRate       = @"com.tm.aiaccel.rate";
static NSString * const kCfgBlockShake = @"com.tm.aiaccel.blockShake";
static NSString * const kCfgBlockClick = @"com.tm.aiaccel.blockClick";
static NSString * const kCfgSkipSplash = @"com.tm.aiaccel.skipSplash";
static NSString * const kCfgBallX      = @"com.tm.aiaccel.ballX";
static NSString * const kCfgBallY      = @"com.tm.aiaccel.ballY";

static BOOL   gEnabled    = YES;
static double gRate       = 8.0;
static BOOL   gBlockShake = YES;
static BOOL   gBlockClick = YES;
static BOOL   gSkipSplash = YES;

static void TMLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AIA] %@", s);
}

#pragma mark - 配置

static void TMLoadConfig(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kCfgEnabled])    gEnabled    = [d boolForKey:kCfgEnabled];
    if ([d objectForKey:kCfgRate])       gRate       = [d doubleForKey:kCfgRate];
    if ([d objectForKey:kCfgBlockShake]) gBlockShake = [d boolForKey:kCfgBlockShake];
    if ([d objectForKey:kCfgBlockClick]) gBlockClick = [d boolForKey:kCfgBlockClick];
    if ([d objectForKey:kCfgSkipSplash]) gSkipSplash = [d boolForKey:kCfgSkipSplash];
    if (gRate < 1.0)  gRate = 1.0;
    if (gRate > 20.0) gRate = 20.0;
}

static void TMSaveConfig(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:gEnabled forKey:kCfgEnabled];
    [d setDouble:gRate forKey:kCfgRate];
    [d setBool:gBlockShake forKey:kCfgBlockShake];
    [d setBool:gBlockClick forKey:kCfgBlockClick];
    [d setBool:gSkipSplash forKey:kCfgSkipSplash];
    [d synchronize];
}

#pragma mark - hook 原语

// 存在则替换，不存在则添加。返回替换前的 IMP，便于转发。
static IMP TMHook(Class c, SEL sel, IMP newImp, const char *types, BOOL *outAdded) {
    if (outAdded) *outAdded = NO;
    if (!c || !sel || !newImp) return NULL;

    Method existed = class_getInstanceMethod(c, sel);
    IMP oldImp = existed ? method_getImplementation(existed) : NULL;
    const char *tp = existed ? method_getTypeEncoding(existed) : types;
    if (!tp) tp = types;

    BOOL added = class_addMethod(c, sel, newImp, tp);
    if (outAdded) *outAdded = added;
    if (!added) {
        class_replaceMethod(c, sel, newImp, tp);
    }
    return oldImp;
}

static IMP TMHookClass(Class cls, SEL sel, IMP newImp, const char *types, BOOL *outAdded) {
    if (outAdded) *outAdded = NO;
    if (!cls || !sel || !newImp) return NULL;
    Class meta = object_getClass(cls);

    Method existed = class_getClassMethod(cls, sel);
    IMP oldImp = existed ? method_getImplementation(existed) : NULL;
    const char *tp = existed ? method_getTypeEncoding(existed) : types;
    if (!tp) tp = types;

    BOOL added = class_addMethod(meta, sel, newImp, tp);
    if (outAdded) *outAdded = added;
    if (!added) {
        class_replaceMethod(meta, sel, newImp, tp);
    }
    return oldImp;
}

// 原始实现指针（供 block 内部调用）
typedef void (*TMVoidFloatFn)(id, SEL, float);
typedef void (*TMVoidFloat2Fn)(id, SEL, float, float);

#pragma mark - 1. 播放速率：AVPlayer

static void TMInstallAVPlayerRate(void) {
    Class pc = NSClassFromString(@"AVPlayer");
    if (pc) {
        SEL s = @selector(setRate:);
        Method m = class_getInstanceMethod(pc, s);
        if (m) {
            const char *tp = method_getTypeEncoding(m);
            IMP orig = method_getImplementation(m);
            TMHook(pc, s,
                imp_implementationWithBlock(^(id self_, float rate) {
                    float r = rate;
                    if (gEnabled && rate > 0) r = (float)(rate * gRate);
                    if (r != rate) TMLog(@"[RATE] AVPlayer %.1f -> %.1f", rate, r);
                    if (orig) ((TMVoidFloatFn)orig)(self_, s, r);
                }), tp, NULL);
            TMLog(@"[RATE] AVPlayer setRate: 已接管");
        }
    }

    Class ic = NSClassFromString(@"AVPlayerItem");
    if (ic) {
        SEL s = @selector(setPlaybackRate:);
        Method m = class_getInstanceMethod(ic, s);
        if (m) {
            const char *tp = method_getTypeEncoding(m);
            IMP orig = method_getImplementation(m);
            TMHook(ic, s,
                imp_implementationWithBlock(^(id self_, float rate) {
                    float r = rate;
                    if (gEnabled && rate > 0) r = (float)(rate * gRate);
                    if (orig) ((TMVoidFloatFn)orig)(self_, s, r);
                }), tp, NULL);
            TMLog(@"[RATE] AVPlayerItem setPlaybackRate: 已接管");
        }
    }
}

#pragma mark - 2. 播放速率：各广告 SDK 自有播放器

static NSArray *TMPlayerClassNames(void) {
    return @[
        @"BaiduMobAdMediaPlayer",
        @"BaiduMobAdVideoView",
        @"BaiduMobAdNativeVideoView",
        @"BaiduMobAdNativeCPUVideoView",
        @"WindAVPlayerManager",
        @"WindAVPlayerView",
        @"WindPlayerView",
        @"WindPlayerManager",
        @"WindPlayerControlView",
        @"ZCVideoPlayer",
        @"ZCVideoViewController",
        @"SobotVideoPlayer",
        @"TZVideoPlayerController",
    ];
}

static void TMInstallSDKPlayerRate(void) {
    NSArray *rateSels = @[@"setRate:", @"setPlaybackRate:", @"setSpeed:", @"setPlaySpeed:"];
    int total = 0;

    for (NSString *cn in TMPlayerClassNames()) {
        Class c = NSClassFromString(cn);
        if (!c) continue;

        int n = 0;
        for (NSString *sn in rateSels) {
            SEL s = sel_registerName(sn.UTF8String);
            Method m = class_getInstanceMethod(c, s);
            if (!m) continue;

            const char *tp = method_getTypeEncoding(m);
            if (!tp) continue;
            IMP orig = method_getImplementation(m);
            __block NSString *clsName = [cn copy];
            __block NSString *selName = [sn copy];

            TMHook(c, s,
                imp_implementationWithBlock(^(id self_, float rate) {
                    float r = rate;
                    if (gEnabled && rate > 0) r = (float)(rate * gRate);
                    if (r != rate) {
                        TMLog(@"[RATE] %@ -%@ %.1f -> %.1f", clsName, selName, rate, r);
                    }
                    if (orig) ((TMVoidFloatFn)orig)(self_, s, r);
                }), tp, NULL);
            n++;
        }
        if (n) { TMLog(@"[RATE] %@ 接管 %d 个入口", cn, n); total += n; }
    }
    TMLog(@"[RATE] SDK 播放器合计 %d 个", total);
}

#pragma mark - 3. 计时器加速

static void TMInstallTimers(void) {
    Class tcls = NSClassFromString(@"NSTimer");
    if (!tcls) return;

    // + scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:
    SEL s1 = sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
    Method m1 = class_getClassMethod(tcls, s1);
    if (m1) {
        const char *tp = method_getTypeEncoding(m1);
        IMP orig = method_getImplementation(m1);
        TMHookClass(tcls, s1,
            imp_implementationWithBlock(^id(id self_, NSTimeInterval ti, id target, SEL sel, id ui, BOOL rep) {
                NSTimeInterval n = (gEnabled && ti > 0.05) ? ti / gRate : ti;
                return ((id (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))orig)(
                    self_, s1, n, target, sel, ui, rep);
            }), tp, NULL);
        TMLog(@"[TIMER] scheduledTimer 已接管");
    }

    // + timerWithTimeInterval:...
    SEL s2 = sel_registerName("timerWithTimeInterval:target:selector:userInfo:repeats:");
    Method m2 = class_getClassMethod(tcls, s2);
    if (m2) {
        const char *tp = method_getTypeEncoding(m2);
        IMP orig = method_getImplementation(m2);
        TMHookClass(tcls, s2,
            imp_implementationWithBlock(^id(id self_, NSTimeInterval ti, id target, SEL sel, id ui, BOOL rep) {
                NSTimeInterval n = (gEnabled && ti > 0.05) ? ti / gRate : ti;
                return ((id (*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))orig)(
                    self_, s2, n, target, sel, ui, rep);
            }), tp, NULL);
        TMLog(@"[TIMER] timerWithTimeInterval 已接管");
    }

    // + scheduledTimerWithTimeInterval:repeats:block:
    SEL s3 = sel_registerName("scheduledTimerWithTimeInterval:repeats:block:");
    Method m3 = class_getClassMethod(tcls, s3);
    if (m3) {
        const char *tp = method_getTypeEncoding(m3);
        IMP orig = method_getImplementation(m3);
        TMHookClass(tcls, s3,
            imp_implementationWithBlock(^id(id self_, NSTimeInterval ti, BOOL rep, id block) {
                NSTimeInterval n = (gEnabled && ti > 0.05) ? ti / gRate : ti;
                return ((id (*)(id, SEL, NSTimeInterval, BOOL, id))orig)(self_, s3, n, rep, block);
            }), tp, NULL);
        TMLog(@"[TIMER] scheduledTimer(repeats:block:) 已接管");
    }
}

#pragma mark - 4. 摇一摇 / 传感器拦截

static void TMInstallMotionBlock(void) {
    Class cm = NSClassFromString(@"CMMotionManager");
    if (!cm) { TMLog(@"[MOTION] CMMotionManager 不存在"); return; }

    // login
    int n = 0;

    // 无参版本
    NSArray *noArg = @[@"startAccelerometerUpdates",
                       @"startGyroUpdates",
                       @"startDeviceMotionUpdates"];
    for (NSString *sn in noArg) {
        SEL s = sel_registerName(sn.UTF8String);
        Method m = class_getInstanceMethod(cm, s);
        if (!m) continue;
        const char *tp = method_getTypeEncoding(m);
        IMP orig = method_getImplementation(m);
        __block NSString *name = [sn copy];
        TMHook(cm, s, imp_implementationWithBlock(^(id self_) {
            if (gBlockShake) { TMLog(@"[MOTION] 拦截 %@", name); return; }
            if (orig) ((void (*)(id, SEL))orig)(self_, s);
        }), tp, NULL);
        n++;
    }

    // 带 queue + handler
    NSArray *withHandler = @[@"startAccelerometerUpdatesToQueue:withHandler:",
                             @"startGyroUpdatesToQueue:withHandler:"];
    for (NSString *sn in withHandler) {
        SEL s = sel_registerName(sn.UTF8String);
        Method m = class_getInstanceMethod(cm, s);
        if (!m) continue;
        const char *tp = method_getTypeEncoding(m);
        IMP orig = method_getImplementation(m);
        __block NSString *name = [sn copy];
        TMHook(cm, s, imp_implementationWithBlock(^(id self_, id q, id h) {
            if (gBlockShake) { TMLog(@"[MOTION] 拦截 %@", name); return; }
            if (orig) ((void (*)(id, SEL, id, id))orig)(self_, s, q, h);
        }), tp, NULL);
        n++;
    }

    // deviceMotion 带 referenceFrame
    SEL ds = sel_registerName("startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:");
    Method dm = class_getInstanceMethod(cm, ds);
    if (dm) {
        const char *tp = method_getTypeEncoding(dm);
        IMP orig = method_getImplementation(dm);
        TMHook(cm, ds, imp_implementationWithBlock(^(id self_, NSUInteger f, id q, id h) {
            if (gBlockShake) { TMLog(@"[MOTION] 拦截 deviceMotion(refFrame)"); return; }
            if (orig) ((void (*)(id, SEL, NSUInteger, id, id))orig)(self_, ds, f, q, h);
        }), tp, NULL);
        n++;
    }

    // UIResponder 的摇一摇事件
    Class resp = NSClassFromString(@"UIResponder");
    SEL ms = sel_registerName("motionEnded:withEvent:");
    Method mm = class_getInstanceMethod(resp, ms);
    if (mm) {
        const char *tp = method_getTypeEncoding(mm);
        IMP orig = method_getImplementation(mm);
        TMHook(resp, ms,
            imp_implementationWithBlock(^(id self_, UIEventSubtype t, id e) {
                if (gBlockShake && t == UIEventSubtypeMotionShake) {
                    TMLog(@"[MOTION] 拦截摇一摇事件");
                    return;
                }
                if (orig) ((void (*)(id, SEL, UIEventSubtype, id))orig)(self_, ms, t, e);
            }), tp, NULL);
        n++;
    }

    TMLog(@"[MOTION] 接管 %d 个传感器入口", n);
}

#pragma mark - 5. 点击跳转拦截

static BOOL TMIsAdJumpURL(NSString *url) {
    if (!url.length) return NO;
    NSString *lc = url.lowercaseString;
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"itms-apps://", @"itunes.apple.com", @"apps.apple.com",
                 @"itms://", @"tbopen://", @"taobao://", @"pinduoduo://",
                 @"openapp.jdmobile", @"snssdk", @"kwai://", @"douyin",
                 @"market://", @"alipays://", @"weixin://", @"mqq://",
                 @"openinstall", @"appscheme"];
    });
    for (NSString *k in keys) {
        if ([lc containsString:k]) return YES;
    }
    return NO;
}

static void TMInstallJumpBlock(void) {
    Class app = NSClassFromString(@"UIApplication");
    if (!app) return;

    // - openURL:
    SEL s1 = sel_registerName("openURL:");
    Method m1 = class_getInstanceMethod(app, s1);
    if (m1) {
        const char *tp = method_getTypeEncoding(m1);
        IMP orig = method_getImplementation(m1);
        TMHook(app, s1, imp_implementationWithBlock(^BOOL(id self_, id u) {
            NSString *str = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString] : nil;
            if (gBlockClick && TMIsAdJumpURL(str)) {
                TMLog(@"[JUMP] 拦截 openURL: %@", str);
                return YES;
            }
            return orig ? ((BOOL (*)(id, SEL, id))orig)(self_, s1, u) : NO;
        }), tp, NULL);
        TMLog(@"[JUMP] -openURL: 已接管");
    }

    // - openURL:options:completionHandler:
    SEL s2 = sel_registerName("openURL:options:completionHandler:");
    Method m2 = class_getInstanceMethod(app, s2);
    if (m2) {
        const char *tp = method_getTypeEncoding(m2);
        IMP orig = method_getImplementation(m2);
        TMHook(app, s2,
            imp_implementationWithBlock(^(id self_, id u, id o, id h) {
                NSString *str = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString] : nil;
                if (gBlockClick && TMIsAdJumpURL(str)) {
                    TMLog(@"[JUMP] 拦截 openURL:options: %@", str);
                    if (h) {
                        void (^cb)(BOOL) = h;
                        cb(YES);
                    }
                    return;
                }
                if (orig) ((void (*)(id, SEL, id, id, id))orig)(self_, s2, u, o, h);
            }), tp, NULL);
        TMLog(@"[JUMP] -openURL:options:completionHandler: 已接管");
    }
}

#pragma mark - 6. 开屏 / 插屏 自动移除

static void TMScanAdViews(UIView *v, int depth) {
    if (!v || depth > 6) return;
    if (gEnabled && gSkipSplash) {
        NSString *cn = NSStringFromClass([v class]);
        BOOL isFullAd = ([cn containsString:@"Splash"] ||
                         [cn containsString:@"splash"] ||
                         [cn containsString:@"FullScreenVideo"] ||
                         [cn containsString:@"Interstitial"] ||
                         [cn containsString:@"RewardVideo"]);
        if (isFullAd && v.superview) {
            TMLog(@"[SPLASH] 移除 %@", cn);
            __weak UIView *weakV = v;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakV removeFromSuperview];
            });
            return;
        }
    }
    for (UIView *sub in v.subviews) TMScanAdViews(sub, depth + 1);
}

static void TMInstallSplashScanner(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t,
        dispatch_time(DISPATCH_TIME_NOW, (uint64_t)(1.0 * NSEC_PER_SEC)),
        (uint64_t)(0.5 * NSEC_PER_SEC),
        (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
        if (!gEnabled || !gSkipSplash) return;
        NSArray *wins = [UIApplication sharedApplication].windows;
        for (UIWindow *w in wins) TMScanAdViews(w, 0);
    });
    dispatch_resume(t);
    TMLog(@"[SPLASH] 扫描器已启动");
}

#pragma mark - 7. 悬浮球

@interface TMAccelBallWindow : UIWindow
@property (nonatomic, strong) UIButton *ballButton;
@end

@implementation TMAccelBallWindow

+ (instancetype)shared {
    static TMAccelBallWindow *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[TMAccelBallWindow alloc] initWithFrame:CGRectMake(300, 200, 44, 44)];
    });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert - 1;
        self.backgroundColor = [UIColor clearColor];
        self.rootViewController = [UIViewController new];
        self.hidden = NO;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = self.bounds;
        b.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.8];
        b.layer.cornerRadius = 22;
        b.layer.masksToBounds = YES;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b setTitle:[NSString stringWithFormat:@"%.0fx", gRate] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        self.ballButton = b;

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [b addGestureRecognizer:pan];

        [self restorePosition];
    }
    return self;
}

- (void)restorePosition {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGFloat x = [d objectForKey:kCfgBallX] ? [d doubleForKey:kCfgBallX] : 300;
    CGFloat y = [d objectForKey:kCfgBallY] ? [d doubleForKey:kCfgBallY] : 200;
    self.frame = CGRectMake(x, y, 44, 44);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self];
    CGPoint c = self.center;
    self.center = CGPointMake(c.x + d.x, c.y + d.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setDouble:self.frame.origin.x forKey:kCfgBallX];
        [ud setDouble:self.frame.origin.y forKey:kCfgBallY];
        [ud synchronize];
    }
}

- (void)onTap {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"广告加速"
                         message:[NSString stringWithFormat:
                                  @"倍率 %.1fx\n摇一摇拦截:%@   跳转拦截:%@",
                                  gRate,
                                  gBlockShake ? @"开" : @"关",
                                  gBlockClick ? @"开" : @"关"]
                  preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [NSString stringWithFormat:@"%.1f", gRate];
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.placeholder = @"1 - 20";
    }];

    [ac addAction:[UIAlertAction actionWithTitle:@"应用倍率"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        double v = [ac.textFields.firstObject.text doubleValue];
        if (v < 1) v = 1;
        if (v > 20) v = 20;
        gRate = v;
        TMSaveConfig();
        [self.ballButton setTitle:[NSString stringWithFormat:@"%.0fx", gRate]
                         forState:UIControlStateNormal];
        TMLog(@"[UI] 倍率 -> %.1fx", gRate);
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"切换摇一摇拦截"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        gBlockShake = !gBlockShake;
        TMSaveConfig();
        TMLog(@"[UI] 摇一摇拦截 -> %@", gBlockShake ? @"开" : @"关");
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"切换跳转拦截"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        gBlockClick = !gBlockClick;
        TMSaveConfig();
        TMLog(@"[UI] 跳转拦截 -> %@", gBlockClick ? @"开" : @"关");
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"隐藏悬浮球"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        self.hidden = YES;
    }]];

    UIViewController *root = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && w != self) { root = w.rootViewController; break; }
    }
    if (!root) root = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (root) [root presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void TMAccelInit(void) {
    @autoreleasepool {
        TMLoadConfig();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TMLog(@"===== AIAccel 启动，倍率 %.1fx =====", gRate);

            TMInstallAVPlayerRate();
            TMInstallSDKPlayerRate();
            TMInstallTimers();
            TMInstallMotionBlock();
            TMInstallJumpBlock();
            TMInstallSplashScanner();

            TMAccelBallWindow *ball = [TMAccelBallWindow shared];
            [ball.ballButton setTitle:[NSString stringWithFormat:@"%.0fx", gRate]
                             forState:UIControlStateNormal];

            TMLog(@"===== 启动完成 =====");
        });
    }
}
