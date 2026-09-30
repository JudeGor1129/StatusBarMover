#import <UIKit/UIKit.h>
#import <notify.h>
#import <unistd.h>

// ============================================================================
//  StatusBarMover 2.0.0 — iOS 15 状态栏图标自由定位
//  目标环境: iPhone 13 Pro Max / iOS 15.4.1 / XinaA15(xina2) / rootless
//
//  ── 工作原理 ──────────────────────────────────────────────────────────────
//  状态栏的每一个图标都是一个 `_UIStatusBarItemView` 子类实例。我们在它每次
//  setFrame: / layoutSubviews 之后，给这个视图叠加一个「平移变换」(transform)
//  来实现位移。
//
//  ★ 为什么用 transform 而不是直接改 frame：
//    frame 由系统的布局引擎掌管，直接改会被下一次布局覆盖，而且会与布局引擎
//    互相反馈（极易触发 SpringBoard watchdog / 安全模式）。transform 是渲染层
//    叠加，不参与约束解算，因此完全无副作用。
//
//  ── 稳定性设计（血泪经验，改动前务必读完）────────────────────────────────
//  1.0.0–1.0.3 全部在 %ctor 里崩溃（EXC_BAD_ACCESS / SIGBUS），原因是 dyld 还在
//  跑 image initializer 的阶段（jbinjector → 本 dylib 构造函数）就调用了
//  Foundation/CoreFoundation，此时 ObjC 常量字符串类引用尚未绑定。
//  那些崩溃是硬件信号，@try 根本抓不住。
//
//  因此 1.0.4 起的铁律，2.0.0 继续遵守：
//    · %ctor 里只做 `%init;`（注册 hook），绝不碰 Foundation/CF。
//    · 所有初始化（开关、读偏好、注册重启通知）用 dispatch_once 延迟到
//      「第一次状态栏布局」时执行 —— 那时 SpringBoard 早就启动完毕。
//    · 紧急开关用 POSIX access() 检查纯 C 字符串路径，连常量 NSString 都不需要。
//
//  紧急开关（装坏了进安全模式也能救回来）：
//      touch /var/mobile/Library/Preferences/com.minis.statusbarmover.disable
//      然后重启 SpringBoard；删除该文件即恢复。
// ============================================================================

@interface _UIStatusBarItemView : UIView
@end

static NSString *const kAppID     = @"com.minis.statusbarmover";
static NSString *const kReload    = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile = @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";
// 故意用 C 字符串：安全检查不依赖任何 ObjC 常量字符串。
static const char *kKillPathC = "/var/mobile/Library/Preferences/com.minis.statusbarmover.disable";

static BOOL                 gKill    = NO;
static BOOL                 gEnabled = YES;
static NSDictionary        *gOffsets = nil;   // { identifier: { x: NSNumber, y: NSNumber } }
static NSMutableDictionary *gSeen    = nil;   // { identifier: className }  —— 用于设置页自动生成列表
static BOOL                 gWritePending = NO;
static dispatch_once_t      gInitOnce;

// ---- 偏好读取（只会在开机之后被调用）---------------------------------------

static void LoadPrefs(void) {
    @try {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);

        NSNumber *en = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
            CFSTR("enabled"), (__bridge CFStringRef)kAppID);
        gEnabled = (en == nil) ? YES : en.boolValue;

        NSDictionary *all = (__bridge_transfer NSDictionary *)
            CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)kAppID,
                                      kCFPreferencesCurrentUser,
                                      kCFPreferencesAnyHost);
        NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
        for (NSString *k in all) {
            if (![k isKindOfClass:NSString.class]) continue;
            NSRange dot = [k rangeOfString:@"." options:NSBackwardsSearch];
            if (dot.location == NSNotFound) continue;
            NSString *axis = [k substringFromIndex:dot.location + 1];
            if (![axis isEqualToString:@"x"] && ![axis isEqualToString:@"y"]) continue;
            NSString *ident = [k substringToIndex:dot.location];
            NSMutableDictionary *e = parsed[ident];
            if (!e) { e = [NSMutableDictionary dictionary]; parsed[ident] = e; }
            e[axis] = all[k];
        }
        gOffsets = [parsed copy];
    } @catch (__unused NSException *e) {
        gOffsets = @{};
    }
}

// ---- 图标分类：让设置页知道哪个标识符是「信号 / 数据 / Wi-Fi / 电池」-------
//
//  iOS 15 的标识符在不同机型/版本上略有差异，这里用「精确名 → 关键字 →
//  视图类名」三级匹配。设置页只是把结果分组展示，即便分类猜错也不会丢功能：
//  「全部图标」页里可以调节任何一个被发现的标识符。

static NSString *SBMCategoryFor(NSString *ident, NSString *cls) {
    NSString *k = ident.lowercaseString ?: @"";
    NSString *c = cls.lowercaseString   ?: @"";

    // 精确名优先（这些是 iOS 15 实测发现的标识符）
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
        [c containsString:@"percent"])                       return @"percent";
    if ([k containsString:@"battery"] || [c containsString:@"battery"]) return @"battery";
    if ([k containsString:@"wifi"] || [k containsString:@"wi-fi"] ||
        [c containsString:@"wifi"])                          return @"wifi";
    if ([k containsString:@"datanetwork"] || [c containsString:@"datanetwork"] ||
        [k containsString:@"networktype"] || [c containsString:@"networktype"]) return @"data";
    if ([k containsString:@"bars"] || [c containsString:@"signal"] ||
        [k containsString:@"signal"])                        return @"signal";
    if ([k containsString:@"time"] || [c containsString:@"time"]) return @"time";
    return @"other";
}

// ---- 节流 + 无竞争的发现结果落盘 -------------------------------------------

static void SBMScheduleWrite(void) {
    if (gWritePending) return;
    gWritePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gWritePending = NO;
        // 写成 [{ key, cls, cat }...]，设置页据此自动生成条目
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *key in [[gSeen allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            NSString *cls = gSeen[key] ?: @"";
            [rows addObject:@{ @"key": key,
                               @"cls": cls,
                               @"cat": SBMCategoryFor(key, cls) }];
        }
        NSArray *snap = [rows copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try { [snap writeToFile:kItemsFile atomically:YES]; }
            @catch (__unused NSException *e) {}
        });
    });
}

// ---- 全窗口强制重新布局（设置页改动后立即生效）-----------------------------

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

// ---- 延迟初始化：第一次状态栏布局时执行（此时早已开机完成）-----------------

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

// 以「平移变换」施加偏移，永不触碰 frame。
static void SBMApplyTransform(UIView *v) {
    @try {
        CGAffineTransform t = CGAffineTransformIdentity;
        if (gEnabled) {
            NSString *key = SBMKeyForItemView(v);
            if (key.length) {
                if (gSeen[key] == nil) {
                    gSeen[key] = NSStringFromClass(v.class) ?: @"";
                    SBMScheduleWrite();
                }
                NSDictionary *off = gOffsets[key];
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
