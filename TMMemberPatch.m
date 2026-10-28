// TMMemberPatch.m  —  TM手游加速器 本地会员/免广告权益解锁
// 目标: com.TMSpeed.Lightning  2.1.8 (CFBundleVersion 21801)
// 产物: TMMemberPatch.dylib (arm64 + arm64e 可选), 供注入使用

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

#pragma mark - 常量

// 2045-11-01 00:00:00 UTC —— 与原图 "有效期至: 2045-11-01" 对齐
static const double kExpireSec = 2398320000.0;
static NSString * const kExpireText = @"2045-11-01";

static void TMLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TMPatch] %@", s);
}

#pragma mark - 安全 hook 原语

// 给类添加方法，若已存在则替换实现（不交换，避免原实现丢失）
static BOOL TMOverrideInstanceMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || !sel || !imp) return NO;
    return class_addMethod(cls, sel, imp, types) ?: YES;
}

// 添加或替换实例方法（存在就 replace）
static void TMForceSetInstanceMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || !sel) return;
    if (class_addMethod(cls, sel, imp, types)) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) class_replaceMethod(cls, sel, imp, types);
}

// block 转 IMP，保留原实现的转发
typedef IMP (^TMIMPFactory)(IMP original);

#pragma mark - 通用 getter 注入

static id TM_ReturnYES(id self, SEL _cmd)  { return @YES; }
static BOOL TM_ReturnBoolYES(id self, SEL _cmd) { return YES; }
static id TM_ReturnExpireDate(id self, SEL _cmd) { return [NSDate dateWithTimeIntervalSince1970:kExpireSec]; }
static id TM_ReturnExpireText(id self, SEL _cmd) { return kExpireText; }
static id TM_ReturnExpireNum(id self, SEL _cmd)  { return @(kExpireSec); }
static long long TM_ReturnZero(id self, SEL _cmd) { return 0; }

static void TMInstallMemberGetters(Class cls, NSString *tag) {
    if (!cls) return;
    struct { const char *name; IMP imp; const char *types; } list[] = {
        { "isVip",         (IMP)TM_ReturnYES,        "@16@0:8" },
        { "isVIP",         (IMP)TM_ReturnYES,        "@16@0:8" },
        { "isSvip",        (IMP)TM_ReturnYES,        "@16@0:8" },
        { "isMember",      (IMP)TM_ReturnYES,        "@16@0:8" },
        { "isAdFree",      (IMP)TM_ReturnYES,        "@16@0:8" },
        { "vipExpireDate", (IMP)TM_ReturnExpireDate, "@16@0:8" },
        { "vipEndDate",    (IMP)TM_ReturnExpireDate, "@16@0:8" },
        { "vipEndTimeStr", (IMP)TM_ReturnExpireText, "@16@0:8" },
        { "adFreeEndTime", (IMP)TM_ReturnExpireText, "@16@0:8" },
        { "adFreeTime",    (IMP)TM_ReturnExpireNum,  "@16@0:8" },
        { "ad_free_time",  (IMP)TM_ReturnExpireNum,  "@16@0:8" },
        { "sendFreeTIme",  (IMP)TM_ReturnZero,       "q16@0:8" },
        { "free_time",     (IMP)TM_ReturnZero,       "q16@0:8" },
    };
    size_t n = sizeof(list) / sizeof(list[0]);
    for (size_t i = 0; i < n; i++) {
        SEL s = sel_registerName(list[i].name);
        TMForceSetInstanceMethod(cls, s, list[i].imp, list[i].types);
    }
    // 无参同义的 BOOL getter
    SEL b = sel_registerName("isVipBool");
    if (!class_getInstanceMethod(cls, b)) class_addMethod(cls, b, (IMP)TM_ReturnBoolYES, "B16@0:8");

    TMLog(@"%@ 会员 getter 已铺(%zu 项)", tag, n);
}

#pragma mark - 用户态字典改写

static NSDictionary *TMPatchDict(NSDictionary *dict, int depth);

static id TMPatchValueForKey(id key, id value) {
    NSString *k = [key isKindOfClass:[NSString class]] ? [key lowercaseString] : @"";
    if (k.length == 0) return value;

    // 1) 布尔标记
    static NSSet *boolKeys;
    static dispatch_once_t once1;
    dispatch_once(&once1, ^{
        boolKeys = [NSSet setWithObjects:
            @"isvip", @"is_vip", @"isvipmember", @"vip", @"svip", @"issvip",
            @"member", @"ismember", @"is_ad_free", @"isadfree", @"adfree",
            @"adafree", @"isvipuser", @"isvalid", nil];
    });
    if ([boolKeys containsObject:k] && ![value isKindOfClass:[NSNull class]]) {
        return @YES;
    }

    // 2) 时间/时长型
    static NSSet *timeKeys;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        timeKeys = [NSSet setWithObjects:
            @"ad_free_time", @"adfreetime", @"free_time", @"freetime",
            @"sendfreetime", @"vip_end_time", @"vipendtime", @"vipend",
            @"expire_time", @"expiretime", @"expire", @"endtime", @"end_time",
            @"ad_end_time", @"adendtime", @"vip_end", nil];
    });
    if ([timeKeys containsObject:k] && [value respondsToSelector:@selector(doubleValue)]) {
        double d = [value doubleValue];
        // 毫秒字段给毫秒，秒字段给秒
        if (d > 1e11) return @(kExpireSec * 1000.0);
        if (d > 0 || [value isKindOfClass:[NSNumber class]]) return @(kExpireSec);
    }

    // 3) 日期字符串
    static NSSet *strKeys;
    static dispatch_once_t once3;
    dispatch_once(&once3, ^{
        strKeys = [NSSet setWithObjects:
            @"vip_end_time_str", @"vipendtimestr", @"expiredate", @"expire_date",
            @"validuntil", @"expired", @"vip_time", @"viptime", nil];
    });
    if ([strKeys containsObject:k] && [value isKindOfClass:[NSString class]]) {
        return kExpireText;
    }

    // 4) 递归
    if ([value isKindOfClass:[NSDictionary class]]) return TMPatchDict(value, depth_hack);
    return value;
}

// 上面无法引外部变量，改用显式版本
static int depth_hack = 0;

static NSDictionary *TMPatchDict(NSDictionary *dict, int depth) {
    if (![dict isKindOfClass:[NSDictionary class]]) return dict;
    if (depth > 8) return dict;

    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:dict.count];
    for (id key in dict) {
        id value = dict[key];
        NSString *k = [key isKindOfClass:[NSString class]] ? [key lowercaseString] : @"";

        id patched = nil;

        if ([[NSSet setWithObjects:@"isvip", @"is_vip", @"isvipmember", @"vip", @"svip",
              @"issvip", @"member", @"ismember", @"is_ad_free", @"isadfree", @"isvipuser", nil]
             containsObject:k] && ![value isKindOfClass:[NSNull class]]) {
            patched = @YES;
        }
        else if ([[NSSet setWithObjects:@"ad_free_time", @"adfreetime", @"free_time", @"freetime",
                   @"sendfreetime", @"vip_end_time", @"vipendtime", @"vipend", @"expire_time",
                   @"expiretime", @"endtime", @"end_time", @"ad_end_time", nil] containsObject:k]) {
            double d = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
            patched = (d > 1e11) ? @(kExpireSec * 1000.0) : @(kExpireSec);
        }
        else if ([[NSSet setWithObjects:@"expiredate", @"expire_date", @"validuntil",
                   @"expired", @"vip_end_time_str", @"vip_time", nil] containsObject:k]
                 && [value isKindOfClass:[NSString class]]) {
            patched = kExpireText;
        }
        else if ([value isKindOfClass:[NSDictionary class]]) {
            patched = TMPatchDict(value, depth + 1);
        }
        else if ([value isKindOfClass:[NSArray class]]) {
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[value count]];
            for (id item in value) {
                [arr addObject:[item isKindOfClass:[NSDictionary class]]
                    ? TMPatchDict(item, depth + 1) : item];
            }
            patched = arr;
        }
        else {
            patched = value;
        }

        m[key ?: @"?"] = patched ?: [NSNull null];
    }
    return m;
}

#pragma mark - NSURLProtocol 响应改写

@interface TMURLProtocol : NSURLProtocol
@end

@implementation TMURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *u = request.URL.absoluteString.lowercaseString;
    if (![u containsString:@"/api/"]) return NO;
    if ([NSURLProtocol propertyForKey:@"TMHandled" inRequest:request]) return NO;

    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"login", @"/user", @"vip", @"/pay", @"order", @"config", @"init",
                 @"real_name", @"history_order"];
    });
    for (NSString *k in keys) {
        if ([u containsString:k]) return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"TMHandled" inRequest:req];

    if (self.request.HTTPBody) {
        id body = [NSJSONSerialization JSONObjectWithData:self.request.HTTPBody options:0 error:NULL];
        if ([body isKindOfClass:[NSDictionary class]]) {
            req.HTTPBody = [NSJSONSerialization dataWithJSONObject:TMPatchDict(body, 0) options:0 error:NULL];
        }
    }

    NSURLSession *session = [NSURLSession sessionWithConfiguration:
                             [NSURLSessionConfiguration defaultSessionConfiguration]];
    __weak typeof(self) weakSelf = self;
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (err) { [s.client URLProtocol:s didFailWithError:err]; return; }

        NSData *out = data;
        if (data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSData *nd = [NSJSONSerialization dataWithJSONObject:TMPatchDict(json, 0) options:0 error:NULL];
                if (nd) out = nd;
                NSDictionary *d = (NSDictionary *)json;
                NSDictionary *ud = d[@"data"] ?: d[@"result"] ?: d;
                if ([ud isKindOfClass:[NSDictionary class]]) {
                    id phone = ud[@"phone"] ?: ud[@"mobile"] ?: ud[@"account"];
                    if (phone) TMLog(@"账号 %@", phone);
                }
            }
        }
        [s.client URLProtocol:s didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [s.client URLProtocol:s didLoadData:out];
        [s.client URLProtocolDidFinishLoading:s];
    }] resume];
}

- (void)stopLoading { }

@end

#pragma mark - 广告层拦截

static id TM_SharedNil(id self, SEL _cmd) { return nil; }
static void TM_Noop(id self, SEL _cmd) { }

// 把 load/show/present/request 开头的方法改成空实现
static void TMKillAdMethods(Class cls, NSString *tag) {
    if (!cls) return;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    int killed = 0;
    for (unsigned int i = 0; i < n; i++) {
        SEL s = method_getName(ms[i]);
        NSString *sn = NSStringFromSelector(s);
        if ([sn hasPrefix:@"load"] || [sn hasPrefix:@"show"] ||
            [sn hasPrefix:@"present"] || [sn hasPrefix:@"request"] ||
            [sn hasPrefix:@"start"]) {
            // 只杀无参或单参的，避免破坏回调签名
            const char *types = method_getTypeEncoding(ms[i]);
            if (types && strlen(types) <= 12) {
                class_replaceMethod(cls, s, (IMP)TM_Noop, types);
                killed++;
            }
        }
    }
    free(ms);
    TMLog(@"%@ 广告方法静默 %d 个", tag, killed);
}

// 单例置 nil
static void TMNullifySingletons(Class cls, NSString *tag) {
    if (!cls) return;
    Class meta = object_getClass(cls);
    NSArray *names = @[@"shared", @"sharedInstance", @"shareManager", @"manager",
                       @"defaultManager", @"share", @"instance"];
    for (NSString *nm in names) {
        SEL s = sel_registerName(nm.UTF8String);
        Method m = class_getClassMethod(cls, s);
        if (m) {
            class_replaceMethod(meta, s, (IMP)TM_SharedNil, method_getTypeEncoding(m));
            TMLog(@"%@ +%@ -> nil", tag, nm);
        }
    }
    // some managers expose -sharedInstance too
    Method im = class_getInstanceMethod(cls, sel_registerName("sharedInstance"));
    if (im) {
        class_replaceMethod(cls, sel_registerName("sharedInstance"), (IMP)TM_SharedNil,
                            method_getTypeEncoding(im));
    }
}

#pragma mark - UI 文案

static void TMSweepLabels(UIView *v, int depth) {
    if (!v || depth > 30) return;
    if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UIButton class]]) {
        NSString *t = nil;
        if ([v isKindOfClass:[UILabel class]]) t = ((UILabel *)v).text;
        else t = [((UIButton *)v) titleForState:UIControlStateNormal];

        BOOL changed = NO;
        NSString *nt = t;
        if ([t containsString:@"有效期至"] || [t containsString:@"有效期至:"]) {
            nt = [NSString stringWithFormat:@"有效期至：%@", kExpireText];
            changed = YES;
        } else if ([t containsString:@"权益仅剩"] || [t containsString:@"剩余时长"]) {
            nt = @"权益有效期：永久";
            changed = YES;
        }
        if (changed && ![nt isEqualToString:t]) {
            if ([v isKindOfClass:[UILabel class]]) ((UILabel *)v).text = nt;
            else [((UIButton *)v) setTitle:nt forState:UIControlStateNormal];
            TMLog(@"文案: %@ -> %@", t, nt);
        }
    }
    for (UIView *sub in v.subviews) TMSweepLabels(sub, depth + 1);
}

#pragma mark - 安装

static Class TMC(NSString *n) {
    Class c = NSClassFromString(n);
    if (!c) TMLog(@"缺类 %@", n);
    return c;
}

static void TMInstallDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *keys = @[@"isVip", @"is_vip", @"isVIP", @"ad_free_time", @"adFreeTime",
                      @"free_time", @"vipEndTime", @"vip_end_time", @"expired", @"adEndTime"];
    for (NSString *k in keys) {
        id old = [d objectForKey:k];
        if (old == nil) continue;
        if ([old isKindOfClass:[NSNumber class]]) {
            double v = [old doubleValue];
            [d setObject:(v > 1e11 ? @(kExpireSec * 1000.0)
                                  : (v > 1 ? @(kExpireSec) : @YES)) forKey:k];
        } else {
            [d setObject:kExpireText forKey:k];
        }
        TMLog(@"NSUserDefaults[%@] 改写", k);
    }
    [d synchronize];
}

static void TMInstallUserHooks(void) {
    // 用户中心
    Class uc = TMC(@"TMLightning.TMUserInfoCenter") ?: TMC(@"TMUserInfoCenter");
    if (uc) {
        TMInstallMemberGetters(uc, @"TMUserInfoCenter");
        Method m = class_getInstanceMethod(uc, sel_registerName("isVip"));
        if (m) class_replaceMethod(uc, sel_registerName("isVip"), (IMP)TM_ReturnYES, "@16@0:8");
    }
    Class ud = TMC(@"TMLightning.TMUserInfoDefaults") ?: TMC(@"TMUserInfoDefaults");
    if (ud) TMInstallMemberGetters(ud, @"TMUserInfoDefaults");
    Class cd = TMC(@"TMLightning.TMCommonDefaults") ?: TMC(@"TMCommonDefaults");
    if (cd) TMInstallMemberGetters(cd, @"TMCommonDefaults");

    // userInfo 返回字典的，包一层改写
    Class lc = TMC(@"TMLightning.TMLightningCenter");
    if (lc) {
        TMInstallMemberGetters(lc, @"TMLightningCenter");
        SEL s = sel_registerName("userInfo");
        Method m = class_getInstanceMethod(lc, s);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP blk = imp_implementationWithBlock(^id(id self_) {
                id v = ((id (*)(id, SEL))orig)(self_, s);
                if ([v isKindOfClass:[NSDictionary class]]) return TMPatchDict(v, 0);
                return v;
            });
            class_replaceMethod(lc, s, blk, method_getTypeEncoding(m));
            TMLog(@"TMLightningCenter -userInfo 已包一层改写");
        }
    }

    // 权益相关界面
    for (NSString *n in @[@"TMLightning.TMAdFreePayView",
                          @"TMLightning.TMAdFreePayViewController",
                          @"TMLightning.TMMineMainView",
                          @"TMLightning.TMAdFreePayTableViewCell",
                          @"TMLightning.TMVIPModePopupView",
                          @"TMLightning.TMVIPModeInfoPopupView",
                          @"TMLightning.TMLightningInterfaceCenter"]) {
        TMInstallMemberGetters(TMC(n), n);
    }
}

static void TMInstallAds(void) {
    NSArray *ads = @[@"TMLightning.TMAdManager",
                     @"TMLightning.TMSplashAdManager",
                     @"TMLightning.TMInterstitialAdManager",
                     @"TMLightning.TMRewardedVideoAdManager",
                     @"TMLightning.TMLookVideoAdViewController"];
    for (NSString *n in ads) {
        Class c = TMC(n);
        if (!c) continue;
        TMNullifySingletons(c, n);
        TMKillAdMethods(c, n);
        TMInstallMemberGetters(c, n);
    }
}

static void TMInstallUI(void) {
    for (NSString *n in @[@"TMLightning.TMAdFreePayViewController",
                          @"TMLightning.TMAdFreePayView",
                          @"TMLightning.TMMineMainView"]) {
        Class c = TMC(n);
        if (!c) continue;
        SEL s = sel_registerName("layoutSubviews");
        Method m = class_getInstanceMethod(c, s);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        class_replaceMethod(c, s,
            imp_implementationWithBlock(^(id self_, SEL cmd) {
                if (orig) ((void (*)(id, SEL))orig)(self_, cmd);
                if ([self_ isKindOfClass:[UIView class]])
                    TMSweepLabels((UIView *)self_, 0);
            }),
            method_getTypeEncoding(m));
        TMLog(@"%@ -layoutSubviews 挂文案刷新", n);
    }
}

static void TMInstallIAP(void) {
    Class c = TMC(@"TMLightning.TMAppleIAPCentre");
    if (c) TMInstallMemberGetters(c, @"TMAppleIAPCentre");
}

__attribute__((constructor))
static void TMInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            TMLog(@"==== 注入开始 (TMLightning 2.1.8) ====");
            [NSURLProtocol registerClass:[TMURLProtocol class]];
            TMInstallDefaults();
            TMInstallUserHooks();
            TMInstallAds();
            TMInstallUI();
            TMInstallIAP();
            TMLog(@"==== 注入完成, 免广告权益 -> %@ ====", kExpireText);
        });
    }
}
