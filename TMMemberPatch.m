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

// 日志同时写文件，不用抓 syslog 也能拿到诊断
static NSString *TMLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 优先写沙盒内，无需越狱权限也能取
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                            NSUserDomainMask, YES);
        NSString *dir = dirs.firstObject ?: NSTemporaryDirectory();
        path = [dir stringByAppendingPathComponent:@"tmpatch.log"];
        // 清空旧日志
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    });
    return path;
}

static void TMLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TMPatch] %@", s);

    // 追加写入文件
    NSString *line = [NSString stringWithFormat:@"%@ [TMPatch] %@\n",
                      [NSDate date], s];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:TMLogPath()];
    if (!fh) {
        [line writeToFile:TMLogPath() atomically:YES
                 encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) { }
    }
}

#pragma mark - 安全 hook 原语

// 添加或替换实例方法（存在就 replace）
static void TMForceSetInstanceMethod(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || !sel) return;
    if (class_addMethod(cls, sel, imp, types)) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) class_replaceMethod(cls, sel, imp, types);
}

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

// 递归收集所有叶子字段名，用于日志核对
static void TMCollectKeys(id obj, NSMutableArray *out, int depth) {
    if (depth > 6 || !out) return;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id k in (NSDictionary *)obj) {
            if ([k isKindOfClass:[NSString class]]) [out addObject:k];
            TMCollectKeys(((NSDictionary *)obj)[k], out, depth + 1);
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            TMCollectKeys(item, out, depth + 1);
        }
    }
}

static NSDictionary *TMPatchDict(NSDictionary *dict, int depth);

// 字段名是否带会员语义。用关键字而非精确名，覆盖逆向没列全的字段。
static BOOL TMKeyLooksMember(NSString *k) {
    if (!k.length) return NO;
    // 排除明显无关的广告 SDK 字段，避免误伤
    if ([k containsString:@"ad_id"] || [k containsString:@"adid"] ||
        [k containsString:@"adslot"] || [k containsString:@"adn_"] ||
        [k containsString:@"adtype"] || [k containsString:@"ad_type"] ||
        [k hasSuffix:@"_ad"] || [k containsString:@"advert"]) {
        return NO;
    }
    if ([k containsString:@"loadad"] || [k containsString:@"show_ad"] ||
        [k containsString:@"splash"] || [k containsString:@"interstitial"] ||
        [k containsString:@"native"]) {
        return NO;
    }

    NSArray *words = @[@"vip", @"adfree", @"ad_free", @"member",
                       @"free_time", @"freetime", @"expire"];
    for (NSString *w in words) {
        if ([k containsString:w]) return YES;
    }
    return NO;
}

static NSDictionary *TMPatchDict(NSDictionary *dict, int depth) {
    if (![dict isKindOfClass:[NSDictionary class]]) return dict;
    if (depth > 8) return dict;

    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:dict.count];
    for (id key in dict) {
        id value = dict[key];
        NSString *k = [key isKindOfClass:[NSString class]] ? [key lowercaseString] : @"";

        id patched = nil;

        // 精确匹配：布尔开关
        if ([[NSSet setWithObjects:@"isvip", @"is_vip", @"isvipmember", @"vip", @"svip",
              @"issvip", @"member", @"ismember", @"is_ad_free", @"isadfree", @"isvipuser", nil]
             containsObject:k] && ![value isKindOfClass:[NSNull class]]) {
            patched = @YES;
        }
        // 精确匹配：时长（秒/毫秒按量级判断）
        else if ([[NSSet setWithObjects:@"ad_free_time", @"adfreetime", @"free_time", @"freetime",
                   @"sendfreetime", @"vip_end_time", @"vipendtime", @"vipend", @"expire_time",
                   @"expiretime", @"endtime", @"end_time", @"ad_end_time", nil] containsObject:k]) {
            double d = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
            patched = (d > 1e11) ? @(kExpireSec * 1000.0) : @(kExpireSec);
        }
        // 精确匹配：日期字符串
        else if ([[NSSet setWithObjects:@"expiredate", @"expire_date", @"validuntil",
                   @"expired", @"vip_end_time_str", @"vip_time", nil] containsObject:k]
                 && [value isKindOfClass:[NSString class]]) {
            patched = kExpireText;
        }
        // 关键字匹配：字段名里带会员语义的，按值类型统一改写
        // 这一步是兜底，覆盖逆向没列全的字段
        else if (TMKeyLooksMember(k)) {
            if ([value isKindOfClass:[NSNumber class]]) {
                // 布尔或小整数 -> YES；时间戳 -> 到期秒数
                NSNumber *num = (NSNumber *)value;
                const char *t = [num objCType];
                if (t && (t[0] == 'c' || t[0] == 'B')) {
                    patched = @YES;                        // @YES 的底层编码
                } else {
                    double d = [num doubleValue];
                    patched = (d > 1e11) ? @(kExpireSec * 1000.0) : @(kExpireSec);
                }
            } else if ([value isKindOfClass:[NSString class]]) {
                NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
                NSNumber *n = [nf numberFromString:(NSString *)value];
                patched = n ? kExpireText : @"";           // 数字串给日期，其他留空
            }
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

    // 全量拦截业务接口，不再靠白名单筛。
    // 原有白名单漏掉了 mobile_data / product_list / ad/get / video_award 四个关键接口。
    static NSArray *exclude;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只排除明显与会员无关的上报类接口，减少干扰
        exclude = @[@"reported", @"common_upload", @"sentry", @"log"];
    });
    for (NSString *k in exclude) {
        if ([u containsString:k]) return NO;
    }
    return YES;
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
                // 把响应里的字段名全部记下来，用于核对真实结构
                NSString *url = resp.URL.absoluteString ?: @"?";
                NSString *shortURL = url.length > 80 ? [url substringFromIndex:url.length - 80] : url;
                NSMutableArray *leafKeys = [NSMutableArray array];
                TMCollectKeys((NSDictionary *)json, leafKeys, 0);
                TMLog(@"[REQ] %@", shortURL);
                TMLog(@"[REQ]   字段: %@", [[NSSet setWithArray:leafKeys] allObjects]);

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

// Swift 类在 ObjC 运行时的注册名是 mangled 形式（如 _TtC11TMLightning16TMUserInfoCenter），
// NSClassFromString 对 "TMLightning.TMUserInfoCenter" 这种点号写法解析不到。
// 这里依次尝试三种写法，任何一个命中即可。
static Class TMC(NSString *n) {
    if (!n.length) return Nil;

    // 1) 原样查（ObjC 类）
    Class c = NSClassFromString(n);
    if (c) return c;

    // 2) 点号形式 -> 去掉模块名，只查类名
    NSString *simple = n;
    NSRange dot = [n rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        simple = [n substringFromIndex:dot.location + 1];
        c = NSClassFromString(simple);
        if (c) {
            TMLog(@"类 %@ 解析为 %@", n, NSStringFromClass(c));
            return c;
        }
    }

    // 3) Swift mangled 形式: _TtC<模块名长度><模块名><类名长度><类名>
    NSString *mod = (dot.location != NSNotFound) ? [n substringToIndex:dot.location] : @"TMLightning";
    NSString *mangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@",
                         (unsigned long)mod.length, mod,
                         (unsigned long)simple.length, simple];
    c = NSClassFromString(mangled);
    if (c) {
        TMLog(@"类 %@ 解析为 %@", n, mangled);
        return c;
    }

    // 4) 兜底：遍历所有已注册类，按后缀匹配
    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *all = (Class *)malloc(sizeof(Class) * count);
        count = objc_getClassList(all, count);
        for (int i = 0; i < count; i++) {
            NSString *cn = NSStringFromClass(all[i]);
            if ([cn hasSuffix:simple] && cn.length <= simple.length + 24) {
                c = all[i];
                TMLog(@"类 %@ 后缀匹配为 %@", n, cn);
                break;
            }
        }
        free(all);
    }

    if (!c) TMLog(@"!! 缺类 %@（四种方式均未找到）", n);
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

#pragma mark - 全局兜底: 扫描所有相关类并注入 getter

// 逆向时能列出的类只是"入口类"。真正决定界面显示的可能是某个 Model、
// ViewModel 或单例，未必在名单里。这里把运行时里所有名字带 vip/adfree/user 的类
// 全部扫一遍，凡是有 is 开头布尔字段的，统一返回"会员态"。
static void TMInstallBroadSweep(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *all = (Class *)malloc(sizeof(Class) * count);
    if (!all) return;
    count = objc_getClassList(all, count);

    int touched = 0;
    NSMutableArray *touchedNames = [NSMutableArray array];

    for (int i = 0; i < count; i++) {
        Class c = all[i];
        NSString *cn = NSStringFromClass(c);
        if (!cn.length) continue;

        NSString *lc = cn.lowercaseString;
        BOOL relevant = [lc containsString:@"vip"] ||
                        [lc containsString:@"adfree"] ||
                        [lc containsString:@"userinfo"] ||
                        [lc containsString:@"member"];
        if (!relevant) continue;

        // 跳过系统类与第三方 SDK，只处理主程序模块的类
        if ([cn hasPrefix:@"NS"] || [cn hasPrefix:@"UI"] || [cn hasPrefix:@"CA"] ||
            [cn hasPrefix:@"_NS"] || [cn hasPrefix:@"__"] ||
            [lc containsString:@"gdt"] || [lc containsString:@"awm"] ||
            [lc containsString:@"baidu"] || [lc containsString:@"bytedance"] ||
            [lc containsString:@"pangle"] || [lc containsString:@"wind"] ||
            [lc containsString:@"sigmob"] || [lc containsString:@"ksad"] ||
            [lc containsString:@"unity"] || [lc containsString:@"applovin"] ||
            [lc containsString:@"inmobi"] || [lc containsString:@"mintegral"]) {
            continue;
        }

        // 只看本模块的类（Swift mangled 名里带 TMLightning）
        if (![cn containsString:@"TMLightning"] && ![cn hasPrefix:@"TM"]) {
            continue;
        }

        // 取出该类已有的全部变量与方法，把疑似会员 getter 改成返回 YES
        BOOL did = NO;

        unsigned int mcount = 0;
        Method *ms = class_copyMethodList(c, &mcount);
        for (unsigned int j = 0; j < mcount; j++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[j]));
            const char *type = method_getTypeEncoding(ms[j]);
            if (!type) continue;

            BOOL isGetter = ([sn hasPrefix:@"is"] || [sn hasPrefix:@"has"] ||
                             [sn hasPrefix:@"could"] || [sn hasPrefix:@"should"] ||
                             [sn hasPrefix:@"can"]);
            if (!isGetter) continue;

            const char *ret = method_copyReturnType(ms[j]);
            BOOL retBool = (ret && (ret[0] == 'c' || ret[0] == 'B'));
            BOOL retObj  = (ret && ret[0] == '@');
            if (ret) free((void *)ret);

            NSString *lcs = sn.lowercaseString;
            BOOL looksMember = ([lcs containsString:@"vip"] ||
                               [lcs containsString:@"member"] ||
                               [lcs containsString:@"adfree"] ||
                               [lcs containsString:@"ad_free"]);

            if (looksMember && retBool) {
                class_replaceMethod(c, method_getName(ms[j]), (IMP)TM_ReturnBoolYES, type);
                did = YES;
            } else if (looksMember && retObj) {
                class_replaceMethod(c, method_getName(ms[j]), (IMP)TM_ReturnYES, type);
                did = YES;
            }
        }
        free(ms);

        // 补齐标准 getter
        TMInstallMemberGetters(c, cn);

        if (did) {
            touched++;
            [touchedNames addObject:cn];
        }
    }

    free(all);
    TMLog(@"宽扫完成: 命中并改写 %d 个类", touched);
    if (touchedNames.count) {
        TMLog(@"宽扫类清单: %@", [touchedNames componentsJoinedByString:@", "]);
    }
}

#pragma mark - 诊断: 导出真实的会员相关类与实例

// 把运行时的实际情况打到日志里，用来核对类名/方法名是否与逆向结果一致。
// 输出在 Console.app 或 idevicesyslog 里，关键字 [TMPatch][DUMP]
static void TMDumpRuntime(void) {
    TMLog(@"[DUMP] ===== 运行时类扫描开始 =====");

    // 1) 目标类是否真的存在
    NSArray *targets = @[@"TMUserInfoCenter", @"TMUserInfoDefaults", @"TMCommonDefaults",
                         @"TMLightningCenter", @"TMLightningInterfaceCenter",
                         @"TMAdFreePayView", @"TMAdFreePayViewController",
                         @"TMAppleIAPCentre", @"TMAdManager", @"TMSplashAdManager",
                         @"TMInterstitialAdManager", @"TMRewardedVideoAdManager",
                         @"TMLookVideoAdViewController"];
    for (NSString *t in targets) {
        NSString *full = [@"TMLightning." stringByAppendingString:t];
        Class c = TMC(full);
        TMLog(@"[DUMP] 类 %-30s -> %s", t.UTF8String, c ? class_getName(c) : "缺失");
    }

    // 2) 扫出所有含 vip/adfree 关键字的类
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *all = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(all, count);

    NSMutableArray *hits = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *cn = NSStringFromClass(all[i]);
        NSString *lc = cn.lowercaseString;
        if ([lc containsString:@"vip"] || [lc containsString:@"adfree"] ||
            [lc containsString:@"userinfo"]) {
            [hits addObject:cn];
        }
    }
    free(all);

    TMLog(@"[DUMP] 命中类 %lu 个", (unsigned long)hits.count);
    for (NSString *cn in [hits sortedArrayUsingSelector:@selector(compare:)]) {
        TMLog(@"[DUMP]   %@", cn);
    }

    // 3) 逐个列出这些类的 getter 方法（is/expire 开头）
    for (NSString *cn in hits) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        unsigned int mcount = 0;
        Method *ms = class_copyMethodList(c, &mcount);
        if (!ms) continue;
        NSMutableArray *getters = [NSMutableArray array];
        for (unsigned int i = 0; i < mcount; i++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[i]));
            if ([sn hasPrefix:@"is"] || [sn hasPrefix:@"get"] ||
                [sn.lowercaseString containsString:@"expire"] ||
                [sn.lowercaseString containsString:@"vip"]) {
                [getters addObject:sn];
            }
        }
        free(ms);
        if (getters.count) {
            TMLog(@"[DUMP] %@: %@", cn, [getters componentsJoinedByString:@", "]);
        }
    }

    // 4) 当前 NSUserDefaults 里的会员相关键
    NSDictionary *defs = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (NSString *k in defs) {
        NSString *lc = k.lowercaseString;
        if ([lc containsString:@"vip"] || [lc containsString:@"ad"] ||
            [lc containsString:@"free"] || [lc containsString:@"user"]) {
            TMLog(@"[DUMP] defaults[%@] = %@", k, defs[k]);
        }
    }

    TMLog(@"[DUMP] ===== 运行时类扫描结束 =====");
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

            // 全局兜底：把运行时里所有会员相关类的 getter 拉满
            TMInstallBroadSweep();

            TMLog(@"==== 注入完成, 免广告权益 -> %@ ====", kExpireText);

            // 延迟 3 秒导出运行时的真实结构，供核对
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                TMDumpRuntime();
            });
        });
    }
}
