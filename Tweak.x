#import <UIKit/UIKit.h>
#import <notify.h>
#import <unistd.h>
#import <sys/stat.h>

// ============================================================================
//  StatusBarMover 2.1.0 — iOS 15 状态栏图标自由定位
//  目标环境: iPhone 13 Pro Max / iOS 15.4.1 / XinaA15(xina2) / rootless
//
//  ── 2.1.0 重大修正（此前一直"没效果"的根因）──────────────────────────────
//  参考一台能正常工作的同类插件（MooreBarX15）的二进制后确认：
//  **iOS 15 里根本不存在 `_UIStatusBarItemView` 这个类**。
//  1.0.x ~ 2.0.x 全部 hook 的是这个不存在的类 → Logos 静默跳过 → 从未生效。
//  真实存在的相关类是：
//      _UIStatusBar                 （状态栏容器）
//      _UIStatusBarItem 及其子类     _UIStatusBarCellularItem / _UIStatusBarTimeItem ...
//      _UIStatusBarDisplayItem      （每个图标的显示项，持有 view）
//      _UIStatusBarSignalView / _UIStatusBarImageView / _UIStatusBarStringView ...
//
//  因此改为：
//    · hook `-[_UIStatusBar layoutSubviews]`    —— 每次重排后统一施加
//    · hook `-[_UIStatusBarItem applyUpdate:toDisplayItem:]` —— 数据更新时施加
//    都通过 displayItem.identifier + item/view 类名定位是哪个图标，
//    再对该图标的 view 叠加平移变换。
//
//  ── 偏好键约定 ───────────────────────────────────────────────────────────
//    固定分类键（与内部标识符解耦，永远对得上）：
//        signal / data / wifi / battery / percent / time  的 .x / .y
//    也支持用具体标识符覆盖（命中时优先）。
//
//  ── 稳定性铁律 ───────────────────────────────────────────────────────────
//  %ctor 里只允许 `%init;`（1.0.0–1.0.3 因为在构造函数里碰 Foundation 而 SIGBUS，
//  dyld 还在跑 image initializer 时 ObjC 常量字符串类引用尚未绑定，@try 抓不住）。
//
//  紧急开关：
//      touch /var/mobile/Library/Preferences/com.minis.statusbarmover.disable
// ============================================================================

@interface _UIStatusBar : UIView
@end
@interface _UIStatusBarItem : NSObject
@end

static NSString *const kAppID     = @"com.minis.statusbarmover";
static NSString *const kReload    = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile = @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";
static const char     *kPrefsPathC = "/var/mobile/Library/Preferences/com.minis.statusbarmover.plist";
static const char     *kKillPathC  = "/var/mobile/Library/Preferences/com.minis.statusbarmover.disable";

static BOOL                 gKill    = NO;
static BOOL                 gEnabled = YES;
static NSDictionary        *gOffsets = nil;
static NSMutableDictionary *gSeen    = nil;   // { 诊断键: @{cls, item, cat} }
static BOOL                 gWritePending = NO;
static dispatch_once_t      gInitOnce;

// ---- 偏好读取（只会在开机之后被调用）---------------------------------------

static void LoadPrefs(void) {
    @try {
        NSDictionary *all = [NSDictionary dictionaryWithContentsOfFile:
                             @"/var/mobile/Library/Preferences/com.minis.statusbarmover.plist"];
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

// 设置页在另一个进程里写偏好，未必发我们的 Darwin 通知 → 按 mtime 轮询（节流 0.75s）
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

// ---- 图标分类：把任意标识符/类名归到固定分类 -------------------------------

static NSString *SBMCategoryFor(NSString *ident, NSString *itemCls, NSString *viewCls) {
    NSString *k  = ident.lowercaseString ?: @"";
    NSString *ic = itemCls.lowercaseString ?: @"";
    NSString *vc = viewCls.lowercaseString ?: @"";

    BOOL isBattery = [k containsString:@"battery"] || [ic containsString:@"battery"] ||
                     [vc containsString:@"battery"];
    if (isBattery) {
        if ([k containsString:@"percent"] || [k containsString:@"detail"] ||
            [k containsString:@"numeric"] || [vc containsString:@"percent"])  return @"percent";
        if ([k containsString:@"charging"])                                    return @"other";
        return @"battery";
    }
    if ([k containsString:@"wifi"] || [ic containsString:@"wifi"] ||
        [vc containsString:@"wifi"])                                           return @"wifi";
    if ([ic containsString:@"cellular"] || [k containsString:@"cellular"] ||
        [ic containsString:@"signal"]) {
        if ([k containsString:@"type"] || [k containsString:@"name"] ||
            [k containsString:@"network"])                                     return @"data";
        if ([k containsString:@"signal"] || [vc containsString:@"signal"])     return @"signal";
        return @"signal";   // 蜂窝项默认按信号处理
    }
    if ([k containsString:@"time"] || [ic containsString:@"time"] ||
        [vc containsString:@"time"])                                           return @"time";
    if ([vc containsString:@"signal"])                                         return @"signal";
    if ([vc containsString:@"percent"])                                        return @"percent";
    return @"other";
}

// ---- 诊断落盘（节流）-------------------------------------------------------

static void SBMScheduleWrite(void) {
    if (gWritePending) return;
    gWritePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gWritePending = NO;
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *key in [[gSeen allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:gSeen[key]];
            d[@"key"] = key;
            [rows addObject:d];
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

static void SBMEnsureLoaded(void) {
    dispatch_once(&gInitOnce, ^{
        gSeen    = [NSMutableDictionary dictionary];
        gOffsets = @{};
        if (access(kKillPathC, F_OK) == 0) { gKill = YES; return; }
        LoadPrefs();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, ReloadNotify,
            (__bridge CFStringRef)kReload, NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    });
}

// ---- 核心：给一个 displayItem 对应的 view 施加偏移 --------------------------

// 取出 _UIStatusBarDisplayItem 的标识符字符串
static NSString *SBMIdentOfDisplayItem(id di) {
    @try {
        id ident = [di valueForKey:@"identifier"];
        if ([ident isKindOfClass:NSString.class]) return ident;
        id s = [ident valueForKey:@"string"];
        if ([s isKindOfClass:NSString.class] && [s length]) return s;
        if ([ident respondsToSelector:@selector(stringRepresentation)])
            return [ident description];
    } @catch (__unused NSException *e) {}
    return nil;
}

static void SBMApplyToDisplayItem(id di, NSString *itemCls) {
    @try {
        if (!di) return;
        NSString *ident = SBMIdentOfDisplayItem(di);
        UIView *view = [di valueForKey:@"view"];
        if (![view isKindOfClass:UIView.class]) return;
        NSString *viewCls = NSStringFromClass(view.class) ?: @"";

        CGAffineTransform t = CGAffineTransformIdentity;
        if (gEnabled && (ident.length || viewCls.length)) {
            NSString *cat = SBMCategoryFor(ident, itemCls, viewCls);

            // 诊断：把真实标识符与归属记录下来
            NSString *diagKey = [NSString stringWithFormat:@"%@|%@|%@", ident ?: @"?",
                                 itemCls ?: @"?", viewCls];
            if (gSeen[diagKey] == nil) {
                gSeen[diagKey] = @{ @"ident": ident ?: @"",
                                    @"item": itemCls ?: @"",
                                    @"view": viewCls,
                                    @"cat": cat };
                SBMScheduleWrite();
            }

            NSDictionary *off = ident.length ? gOffsets[ident] : nil;
            if (!off && ![cat isEqualToString:@"other"]) off = gOffsets[cat];
            if (off) {
                CGFloat dx = [off[@"x"] doubleValue];
                CGFloat dy = [off[@"y"] doubleValue];
                if (dx != 0.0 || dy != 0.0)
                    t = CGAffineTransformMakeTranslation(dx, dy);
            }
        }
        if (!CGAffineTransformEqualToTransform(view.transform, t))
            view.transform = t;

        // 位移后别被父视图裁掉
        if (view.superview) view.superview.clipsToBounds = NO;
    } @catch (__unused NSException *e) {}
}

// 遍历一个 _UIStatusBarItem 的所有 displayItem
static void SBMApplyToItem(id item) {
    @try {
        if (!item) return;
        NSString *itemCls = NSStringFromClass([item class]) ?: @"";
        id dis = [item valueForKey:@"displayItems"];
        if ([dis respondsToSelector:@selector(count)]) {
            for (id di in dis) SBMApplyToDisplayItem(di, itemCls);
        }
    } @catch (__unused NSException *e) {}
}

// 遍历整条状态栏
static void SBMApplyToStatusBar(id bar) {
    @try {
        SBMRefreshIfStale();
        id items = [bar valueForKey:@"items"];
        if (![items respondsToSelector:@selector(count)]) return;
        for (id item in items) SBMApplyToItem(item);
    } @catch (__unused NSException *e) {}
}

// ---- hooks -----------------------------------------------------------------

%hook _UIStatusBar

- (void)layoutSubviews {
    %orig;
    SBMEnsureLoaded();
    if (gKill) return;
    SBMApplyToStatusBar(self);
}

- (void)didMoveToWindow {
    %orig;
    SBMEnsureLoaded();
    if (gKill) return;
    SBMApplyToStatusBar(self);
}

%end

%hook _UIStatusBarItem

- (id)applyUpdate:(id)update toDisplayItem:(id)displayItem {
    id ret = %orig;
    SBMEnsureLoaded();
    if (!gKill) SBMApplyToDisplayItem(displayItem, NSStringFromClass([self class]));
    return ret;
}

%end

// ---- 构造函数：只注册 hook，绝不碰 Foundation -------------------------------

%ctor {
    %init;
}
