//
//  SBMRootListController.m — StatusBarMover 主设置页
//
//  设计目标：不出现任何「标识符」这种开发者术语，用户看到的就是
//  「信号 / 数据网络 / Wi-Fi / 电池 / 电量百分比 / 时间」六组，拖一下就好。
//  标识符由插件在设备上实测发现后写入 items.plist，本页自动读取生成。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "SBMCommon.h"
#import "SBMPreviewView.h"

// 只是补一个声明：PSListController 的 table 访问器在开发头文件里未必出现
@interface PSListController (SBMPrivate)
- (UITableView *)table;
@end

@interface SBMRootListController : PSListController <SBMPreviewViewDelegate>
@end

@implementation SBMRootListController {
    SBMPreviewView *_preview;
    CFTimeInterval  _lastFlush;
    BOOL            _flushScheduled;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"StatusBarMover";
    [self sbm_installPreview];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 每次进入本页都按最新数值重建一次，保证「当前数值」行是准的
    [self sbm_rebuild];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sbm_flushNow];  // 离开页面时确保最后一次改动已落盘
}

- (void)sbm_installPreview {
    CGFloat w = CGRectGetWidth(self.view.bounds);
    if (w <= 0) w = CGRectGetWidth(UIScreen.mainScreen.bounds);

    NSArray *items = SBMDiscoveredItems();
    NSMutableDictionary *catToKey = [NSMutableDictionary dictionary];
    for (NSString *cat in SBMCategoryOrder()) {
        NSString *k = SBMKeyForCategory(items, cat, NULL);
        if (k) catToKey[cat] = k;
    }

    // 每次都重建：标识符可能随着图标出现/消失而变化，重建最保险
    _preview = [[SBMPreviewView alloc] initWithWidth:w keys:catToKey];
    _preview.delegate = self;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 112)];
    header.backgroundColor = UIColor.clearColor;
    _preview.frame = header.bounds;
    _preview.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:_preview];

    UITableView *tv = nil;
    @try { tv = self.table; } @catch (__unused NSException *e) {}
    if (!tv && [self.view isKindOfClass:UITableView.class]) tv = (UITableView *)self.view;
    if (!tv) {
        for (UIView *sub in self.view.subviews) {
            if ([sub isKindOfClass:UITableView.class]) { tv = (UITableView *)sub; break; }
        }
    }
    if (tv) tv.tableHeaderView = header;
}

#pragma mark - 偏好读写

- (void)sbm_flushNow {
    _lastFlush = CFAbsoluteTimeGetCurrent();
    CFPreferencesAppSynchronize((__bridge CFStringRef)SBMAppID);
    notify_post(SBMLoadNotif.UTF8String);
}

// 拖动/滑动时高频写入，节流到 ~10Hz，并保证最后一次一定落盘
- (void)sbm_write:(NSString *)key value:(id)value {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)SBMAppID);
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _lastFlush > 0.10) {
        [self sbm_flushNow];
    } else if (!_flushScheduled) {
        _flushScheduled = YES;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self->_flushScheduled = NO;
            [self sbm_flushNow];
        });
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    // 注意：这里刻意不刷新列表里的「当前数值」行 —— 拖动滑块时重载单元格会打断
    // 手势。真正的反馈是屏幕顶端那条实时变化的状态栏，那才是最直观的。
    [self sbm_write:key value:value];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id v = SBMReadRaw(key);
    if (v == nil) return [specifier propertyForKey:@"default"];
    if ([v isKindOfClass:NSNumber.class]) return v;
    if ([v isKindOfClass:NSString.class]) return @([v doubleValue]);   // 兼容旧版文本框数据
    return [specifier propertyForKey:@"default"];
}

// 「当前数值」那一行显示的文本
- (id)summaryFor:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"sbmKey"];
    if (!key.length) return @"";
    return [NSString stringWithFormat:@"水平 %+.0f pt　·　垂直 %+.0f pt",
            SBMOffset(key, @"x"), SBMOffset(key, @"y")];
}

#pragma mark - 生成条目

- (PSSpecifier *)sbm_sliderNamed:(NSString *)name key:(NSString *)key axis:(NSString *)axis {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:nil
                                                       cell:PSSliderCell
                                                       edit:nil];
    [sp setProperty:SBMAppID forKey:@"defaults"];
    [sp setProperty:[NSString stringWithFormat:@"%@.%@", key, axis] forKey:@"key"];
    [sp setProperty:@0 forKey:@"default"];
    [sp setProperty:@([axis isEqualToString:@"x"] ? -60 : -25) forKey:@"minValue"];
    [sp setProperty:@([axis isEqualToString:@"x"] ?  60 :  25) forKey:@"maxValue"];
    [sp setProperty:@YES forKey:@"isContinuous"];
    [sp setProperty:key forKey:@"sbmKey"];     // 归组用（同一图标的 x/y/数值 共用）
    [sp setProperty:@YES forKey:@"sbmIsOffset"];
    return sp;
}

- (void)sbm_addCategory:(NSString *)cat
                     to:(NSMutableArray *)out
               detected:(BOOL)detected
                    key:(NSString *)key
                ordering:(NSUInteger)order {
    PSSpecifier *grp = [PSSpecifier emptyGroupSpecifier];
    [grp setProperty:[NSString stringWithFormat:@"%lu. %@",
                      (unsigned long)order, SBMCategoryTitle(cat)] forKey:@"label"];
    if (!key.length) {
        [grp setProperty:@"这台设备上暂未检测到该图标，开启对应功能后重新打开本页即可。"
                 forKey:@"footerText"];
        [out addObject:grp];
        return;
    }
    [grp setProperty:detected
        ? [NSString stringWithFormat:@"已检测到 · 标识符 %@", key]
        : [NSString stringWithFormat:@"未检测到（先用预置标识符 %@ 保存，功能开启后自动生效）", key]
             forKey:@"footerText"];
    [out addObject:grp];

    [out addObject:[self sbm_sliderNamed:@"水平偏移" key:key axis:@"x"]];
    [out addObject:[self sbm_sliderNamed:@"垂直偏移" key:key axis:@"y"]];

    PSSpecifier *sum = [PSSpecifier preferenceSpecifierNamed:@"当前数值"
                                                      target:self
                                                         set:nil
                                                         get:@selector(summaryFor:)
                                                      detail:nil
                                                        cell:PSTitleValueCell
                                                        edit:nil];
    [sum setProperty:key forKey:@"sbmKey"];
    [sum setProperty:@YES forKey:@"sbmSummary"];
    [out addObject:sum];
}

- (NSMutableArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *s = [NSMutableArray array];
    NSArray *items = SBMDiscoveredItems();

    // ---- 说明 + 总开关 ----
    PSSpecifier *g0 = [PSSpecifier emptyGroupSpecifier];
    [g0 setProperty:@"拖一拖上面的预览就能调位置；下面的滑块可以做 ±1pt 的精细修正。"
                     "所有改动立即生效，不需要重启。"
             forKey:@"footerText"];
    [s addObject:g0];

    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"启用 StatusBarMover"
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:nil
                                                       cell:PSSwitchCell
                                                       edit:nil];
    [sw setProperty:SBMAppID forKey:@"defaults"];
    [sw setProperty:@"enabled" forKey:@"key"];
    [sw setProperty:@YES forKey:@"default"];
    [s addObject:sw];

    // ---- 六组图标 ----
    NSUInteger order = 1;
    for (NSString *cat in SBMCategoryOrder()) {
        BOOL detected = NO;
        NSString *key = SBMKeyForCategory(items, cat, &detected);
        [self sbm_addCategory:cat to:s detected:detected key:key ordering:order++];
    }

    // ---- 其他 ----
    PSSpecifier *g2 = [PSSpecifier emptyGroupSpecifier];
    [g2 setProperty:@"本页以外的图标（蓝牙、定位、闹钟、运营商文字……）在下一层页面里。"
             forKey:@"footerText"];
    [s addObject:g2];

    PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:@"全部图标（高级）"
                                                       target:self
                                                          set:nil
                                                          get:nil
                                                       detail:NSClassFromString(@"SBMItemsController")
                                                         cell:PSLinkCell
                                                         edit:nil];
    [s addObject:link];

    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"重置全部偏移"
                                                        target:self
                                                           set:nil
                                                           get:nil
                                                        detail:nil
                                                          cell:PSButtonCell
                                                          edit:nil];
    [reset setProperty:@YES forKey:@"enabled"];
    [reset setButtonAction:@selector(sbm_resetAll)];
    [s addObject:reset];

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:@"重启 SpringBoard"
                                                           target:self
                                                              set:nil
                                                              get:nil
                                                           detail:nil
                                                             cell:PSButtonCell
                                                             edit:nil];
    [respring setProperty:@YES forKey:@"enabled"];
    [respring setButtonAction:@selector(sbm_respring)];
    [s addObject:respring];

    _specifiers = s;
    return _specifiers;
}

#pragma mark - 按钮

- (void)sbm_resetAll {
    SBMClearAllOffsets(SBMDiscoveredItems());
    // 预置名也一并清掉，避免残留
    for (NSString *cat in SBMCategoryOrder()) {
        NSString *k = SBMKeyForCategory(SBMDiscoveredItems(), cat, NULL);
        if (k.length) {
            SBMSetOffset(k, @"x", 0, NO);
            SBMSetOffset(k, @"y", 0, NO);
        }
    }
    [self sbm_flushNow];
    [self sbm_rebuild];
}

- (void)sbm_respring {
    [self sbm_flushNow];
    SBMRespring();
}

- (void)sbm_rebuild {
    _specifiers = nil;
    [self reloadSpecifiers];
    [self sbm_installPreview];
}

#pragma mark - SBMPreviewViewDelegate

- (void)previewDidFinishDragging:(SBMPreviewView *)view {
    [self sbm_flushNow];
    [self sbm_rebuild];
}

@end
