#import <UIKit/UIKit.h>
#import <notify.h>
#import <unistd.h>
#import <sys/stat.h>

// ============================================================================
//  StatusBarMover 2.0.6 — iOS 15 状态栏图标自由定位
//  目标环境: iPhone 13 Pro Max / iOS 15.4.1 / XinaA15(xina2) / rootless
//
//  ── 工作原理 ──────────────────────────────────────────────────────────────
//  状态栏的每一个图标都是一个 `_UIStatusBarItemView` 子类实例。在它每次
//  setFrame: / layoutSubviews 之后，给这个视图叠加一个「平移变换」(transform)
//  来实现位移。
//
//  ★ 为什么用 transform 而不是直接改 frame：
//    frame 由系统布局引擎掌管，直接改会被下一次布局覆盖，并且会与布局引擎
//    互相反馈（极易触发 SpringBoard watchdog）。transform 属于渲染层叠加，
//    不参与约束解算，零副作用。
//
//  ── 偏好键约定（2.0.6 起）────────────────────────────────────────────────
//    固定分类键（设置页用这些，与内部标识符无关，永远对得上）：
//        signal.x / signal.y        信号
//        data.x   / data.y          数据网络类型 (5G/4G)
//        wifi.x   / wifi.y          Wi-Fi
//        battery.x/ battery.y       电池
//        percent.x/ percent.y       电量百分比
//        time.x   / time.y          时间
//    也支持用「具体标识符」做更精细的覆盖，例如 wifi.x / cellularBars.x，
//    命中时优先于分类键。
//
//  ── 稳定性铁律（改动前务必读完）──────────────────────────────────────────
//  1.0.0–1.0.3 全部在 %ctor 里崩溃（EXC_BAD_ACCESS / SIGBUS）：dyld 还在跑
//  image initializer 的阶段就调用了 Foundation/CoreFoundation，此时 ObjC 常量
//  字符串的类引用尚未绑定。那是硬件信号，@try 抓不住。
//  因此：%ctor 里只允许 `%init;`，其余初始化一律 dispatch_once 延迟到首次布局。
//
//  紧急开关（装坏了进安全模式也能救）：
//      touch /var/mobile/Library/Preferences/com.minis.statusbarmover.disable
// ============================================================================

@interface _UIStatusBarItemView : UIView
@end

static NSString *const kAppID     = @"com.minis.statusbarmover";
static NSString *const kReload    = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile = @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";
static const char     *kPrefsPathC = "/var/mobile/Library/Preferences/com.minis.statusbarmover.plist";
// 故意用 C 字符串：安全检查不依赖任何 ObjC 常量字符串。
static const char     *kKillPathC  = "/var/mobile/Library/Preferences/com.minis.statusbarmover.disable";

static BOOL                 gKill    = NO;
static BOOL                 gEnabled = YES;
static BOOL                 gPrefsFound = NO;   // 偏好文件是否存在（自检用）
static NSDictionary        *gOffsets = nil;   // { 键: { x: NSNumber, y: NSNumber } }
static NSMutableDictionary *gSeen    = nil;   // { 标识符: 类名 } —— 供诊断
static BOOL                 gWritePending = NO;
static dispatch_once_t      gInitOnce;

// ---- 偏好读取（只会在开机之后被调用）---------------------------------------

static void LoadPrefs(void) {
    @try {
        // 直接读 plist 文件：绕过 CFPreferences 的进程内缓存，
        // 这样设置页（另一个进程）写入后能立刻被 SpringBoard 看到。
        NSDictionary *all = [NSDictionary dictionaryWithContentsOfFile:
                             @"/var/mobile/Library/Preferences/com.minis.statusbarmover.plist"];
        gPrefsFound = [all isKindOfClass:NSDictionary.class];
        if (![all isKindOfClass:NSDictionary.class]) all = @{};

        id en = all[@"enabled"];
        gEnabled = en ? ([en respondsToSelector:@selector(boolValue)] ? [en boolValue] : YES) : YES;

        NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
        for (NSString *k in all) {
            if (![k isKindOfClass:NSString.class]) continue;
            NSRange dot = [k rangeOfString:@"." options:NSBackwardsSearch];
            if (dot.location == NSNotFound) continue;
            NSString *axis = [k substringFromIndex:dot.location + 1];
            if (![axis isEqualToString:@"x"] && ![axis isEqualToString:@"y"]) continue;
            NSString *group = [k substringToIndex:dot.location];
            NSMutableDictionary *e = parsed[group];
            if (!e) { e = [NSMutableDictionary dictionary]; parsed[group] = e; }
            e[axis] = all[k];
        }
        gOffsets = [parsed copy];
    } @catch (__unused NSException *e) {
        gOffsets = @{};
    }
}

// 设置页是纯 plist 页面（由 Preferences 自己渲染），不会发我们的 Darwin 通知，
// 所以这里按 mtime 轮询一次偏好文件（节流到 0.75s，代价一次 stat）。
static void SBMRefreshIfStale(void) {
    static CFAbsoluteTime sLastCheck = 0;
    static CFAbsoluteTime sLastMTime = -1;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastCheck < 0.75) return;
    sLastCheck = now;
    struct stat st;
    if (stat(kPrefsPathC, &st) != 0) return;
    CFAbsoluteTime m = (CFAbsoluteTime)st.st_mtimespec.tv_sec
                     + (CFAbsoluteTime)st.st_mtimespec.tv_nsec / 1000000000.0;
    if (m != sLastMTime) { sLastMTime = m; LoadPrefs(); }
}

// ---- 图标分类：让固定分类键生效 --------------------------------------------
//
//  iOS 15 的标识符在不同机型/版本上略有差异，这里用「精确名 → 关键字 →
//  视图类名」三级匹配，把每个图标归到固定的分类上。

static NSString *SBMCategoryFor(NSString *ident, NSString *cls) {
    NSString *k = ident.lowercaseString ?: @"";
    NSString *c = cls.lowercaseString   ?: @"";

    // 实测标识符精确匹配
    if ([k isEqualToString:@"batterydetail"])  return @"percent";
    if ([k isEqualToString:@"batterypercent"]) return @"percent";
    if ([k isEqualToString:@"battery"])        return @"battery";
    if ([k isEqualToString:@"wifi"])           return @"wifi";
    if ([k isEqualToString:@"datanetwork"])    return @"data";
    if ([k isEqualToString:@"cellularbars"])   return @"signal";
    if ([k isEqualToString:@"timestring"])     return @"time";
    if ([k isEqualToString:@"rawsignal"])      return @"other";   // 运营商文字

    // 关键字 / 类名
    if ([k containsString:@"percent"] || [k containsString:@"detail"] ||
        [c containsString:@"percent"])                                   return @"percent";
    if ([k containsString:@"battery"] || [c containsString:@"battery"])   return @"battery";
    if ([k containsString:@"wifi"] || [k containsString:@"wi-fi"] ||
        [c containsString:@"wifi"])                                       return @"wifi";
    if ([k containsString:@"datanetwork"] || [c containsString:@"datanetwork"] ||
        [k containsString:@"networktype"] || [c containsString:@"networktype"]) return @"data";
    if ([k containsString:@"bars"] || [c containsString:@"signal"] ||
        [k containsString:@"signal"])                                     return @"signal";
    if ([k containsString:@"time"] || [c containsString:@"time"])         return @"time";
    return @"other";
}

// ---- 节流 + 无竞争的诊断落盘 -----------------------------------------------

static void SBMScheduleWrite(void) {
    if (gWritePending) return;
    gWritePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gWritePending = NO;
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *key in [[gSeen allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            NSString *cls = gSeen[key] ?: @"";
            [rows addObject:@{ @"key": key, @"cls": cls,
                               @"cat": SBMCategoryFor(key, cls) }];
        }
        NSArray *snap = [rows copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try { [snap writeToFile:kItemsFile atomically:YES]; }
            @catch (__unused NSException *e) {}
        });
    });
}

// ---- 全窗口强制重新布局 -----------------------------------------------------

static void SBMRelayoutIn(UIView *v) {
    if ([v isKindOfClass:NSClassFromString(@"_UIStatusBar")]) {
        [v setNeedsLayout];
        [v layoutIfNeeded];
    }
    for (UIView *sub in v.subviews) SBMRelayoutIn(sub);
}

static void ReloadNotify(CFNotificationCenterRef c, void *o, CFStringRef n,
                         const void *obj, CFDictionaryRef ui) {
    LoadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    SBMRelayoutIn(w);
            }
        } @catch (__unused NSException *e) {}
    });
}

// ---- 延迟初始化：第一次状态栏布局时执行 ------------------------------------

static void SBMEnsureLoaded(void) {
    dispatch_once(&gInitOnce, ^{
        gSeen    = [NSMutableDictionary dictionary];
        gOffsets = @{};
        if (access(kKillPathC, F_OK) == 0) { gKill = YES; return; }  // POSIX 紧急开关
        LoadPrefs();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, ReloadNotify,
            (__bridge CFStringRef)kReload, NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    });
}

// ---- 通过 KVC 安全推导标识符（不用裸 performSelector:）---------------------

static NSString *SBMKeyForItemView(UIView *v) {
    @try {
        id item = [v valueForKey:@"item"];
        if (item) {
            @try {
                id di = [item valueForKey:@"displayItem"];
                id ident = di ? [di valueForKey:@"identifier"] : nil;
                if ([ident isKindOfClass:NSString.class] && [ident length])
                    return ident;
            } @catch (__unused NSException *e) {}
            @try {
                id nm = [item valueForKey:@"indicatorName"];
                if ([nm isKindOfClass:NSString.class] && [nm length])
                    return nm;
            } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}
    return NSStringFromClass(v.class);   // 兜底：一定安全
}

// 取偏移：优先「具体标识符」，否则退回「固定分类键」
static NSDictionary *SBMOffsetFor(NSString *ident, NSString *cls) {
    NSDictionary *off = gOffsets[ident];
    if (off) return off;
    NSString *cat = SBMCategoryFor(ident, cls);
    if (cat.length && ![cat isEqualToString:@"other"]) return gOffsets[cat];
    return nil;
}

// 以「平移变换」施加偏移，永不触碰 frame。
static void SBMApplyTransform(UIView *v) {
    @try {
        SBMRefreshIfStale();
        CGAffineTransform t = CGAffineTransformIdentity;
        if (gEnabled) {
            NSString *key = SBMKeyForItemView(v);
            if (key.length) {
                if (gSeen[key] == nil) {
                    gSeen[key] = NSStringFromClass(v.class) ?: @"";
                    SBMScheduleWrite();
                }
                NSDictionary *off = SBMOffsetFor(key, NSStringFromClass(v.class));
                if (!off && !gPrefsFound) {
                    // ── 自检兜底（仅当偏好文件完全不存在时生效）──────────────
                    // 给「信号」图标一个明显的固定偏移。这样一次安装就能区分三种情况：
                    //   · 信号移动 12pt、Wi-Fi 移动 -12pt → 偏好链路整体正常
                    //   · 只有信号移动 20pt            → hook 正常，偏好读取有问题
                    //   · 什么都不动                   → hook 未生效（或未注入）
                    NSString *cat = SBMCategoryFor(key, NSStringFromClass(v.class));
                    if ([cat isEqualToString:@"signal"]) off = @{ @"x": @20, @"y": @0 };
                }
                if (off) {
                    CGFloat dx = [off[@"x"] doubleValue];
                    CGFloat dy = [off[@"y"] doubleValue];
                    if (dx != 0.0 || dy != 0.0)
                        t = CGAffineTransformMakeTranslation(dx, dy);
                }
            }
        }
        if (!CGAffineTransformEqualToTransform(v.transform, t))
            v.transform = t;
    } @catch (__unused NSException *e) {}
}

// ---- hooks（偏移以 transform 施加，%orig 永远照常调用）---------------------

%hook _UIStatusBarItemView

- (void)setFrame:(CGRect)frame {
    %orig(frame);            // 原样调用 → 与布局引擎零反馈
    SBMEnsureLoaded();       // 首次真实布局时完成初始化（开机后）
    if (gKill) return;
    SBMApplyTransform(self);
}

- (void)layoutSubviews {
    %orig;
    SBMEnsureLoaded();
    if (gKill) return;
    SBMApplyTransform(self);
}

- (void)didMoveToSuperview {
    %orig;
    SBMEnsureLoaded();
    if (gKill) return;
    // 图标被平移到边界外时不要被父视图裁掉
    @try { if (self.superview) self.superview.clipsToBounds = NO; }
    @catch (__unused NSException *e) {}
}

%end

// ---- 构造函数：只注册 hook，绝不碰 Foundation（见文件头注释）---------------

%ctor {
    %init;
}
