//
//  SBMRootListController.m — StatusBarMover 主设置页
//
//  【2.0.1 稳定性改动 / 崩溃修复】说明：
//  1) 不再直接读写父类的 `_specifiers` 实例变量。
//     私有头文件里的 ivar 偏移量可能与 iOS 15 真实布局不一致（编译期硬编码偏移），
//     一旦不一致就是内存踩踏 → 闪退。现在改用：
//       · 自己的关联对象(objc_setAssociatedObject)做缓存
//       · [self setValue:forKey:@"specifiers"] 走**真实 setter**（运行时算偏移，安全）
//  2) 滑块单元格的属性键修正为 min / max（之前误写成 minValue / maxValue，
//     会导致滑块范围退化成 0…1）。同时用 showValue 直接显示数值，
//     于是彻底移除了有风险的 PSTitleValueCell 行。
//  3) 进入页面时不再调用 reloadSpecifiers（避开生命周期早期的重入），
//     改为 viewDidAppear 后在下一个 runloop 里刷新预览与滑块。
//  4) 条目构建、私有 API 调用全部包 @try，任何异常都只会少显示几行，绝不闪退。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import "SBMCommon.h"
#import "SBMPreviewView.h"

// 只是补一个声明：PSListController 的 table 访问器在开发头文件里未必出现
@interface PSListController (SBMPrivate)
- (UITableView *)table;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface SBMRootListController : PSListController <SBMPreviewViewDelegate>
@end

static const void *kSBMSpecsKey = &kSBMSpecsKey;

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

// 页面已经完全出现之后再刷新，避免在 viewWillAppear 里重排表格导致的重入问题
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self sbm_installPreview];
        [self sbm_refreshSliderCells];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sbm_flushNow];  // 离开页面时确保最后一次改动已落盘
}

#pragma mark - 预览

- (void)sbm_installPreview {
    @try {
        CGFloat w = CGRectGetWidth(self.view.bounds);
        if (w <= 0) w = CGRectGetWidth(UIScreen.mainScreen.bounds);
        if (w <= 0) return;

        NSArray *items = SBMDiscoveredItems();
        NSMutableDictionary *catToKey = [NSMutableDictionary dictionary];
        for (NSString *cat in SBMCategoryOrder()) {
            NSString *k = SBMKeyForCategory(items, cat, NULL);
            if (k) catToKey[cat] = k;
        }

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
        if (tv) {
            @try { tv.tableHeaderView = header; } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}
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
    // 刻意不在这里刷新列表 —— 拖动滑块时重载单元格会打断手势。
    // 真正的反馈是屏幕顶端那条实时变化的状态栏。
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

#pragma mark - 生成条目

- (PSSpecifier *)sbm_sliderNamed:(NSString *)name key:(NSString *)key axis:(NSString *)axis {
    BOOL isX = [axis isEqualToString:@"x"];
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
    // 注意：PSSliderCell 用的是 min / max，不是 minValue / maxValue
    [sp setProperty:@(isX ? -60 : -25) forKey:@"min"];
    [sp setProperty:@(isX ?  60 :  25) forKey:@"max"];
    [sp setProperty:@YES forKey:@"showValue"];
    [sp setProperty:@YES forKey:@"isContinuous"];
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
    [grp setProperty:(detected
        ? [NSString stringWithFormat:@"已检测到 · 标识符 %@   ·   当前 X %+.0f / Y %+.0f",
             key, SBMOffset(key, @"x"), SBMOffset(key, @"y")]
        : [NSString stringWithFormat:@"未检测到（先用预置标识符 %@ 保存，功能开启后自动生效）", key])
             forKey:@"footerText"];
    [out addObject:grp];

    [out addObject:[self sbm_sliderNamed:@"水平偏移" key:key axis:@"x"]];
    [out addObject:[self sbm_sliderNamed:@"垂直偏移" key:key axis:@"y"]];
}

- (NSMutableArray *)sbm_buildSpecifiers {
    NSMutableArray *s = [NSMutableArray array];
    NSArray *items = SBMDiscoveredItems();

    // ---- 说明 + 总开关 ----
    PSSpecifier *g0 = [PSSpecifier emptyGroupSpecifier];
    [g0 setProperty:@"拖一拖上面的预览就能调位置；下面的滑块可以做 1pt 的精细修正。"
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

    return s;
}

- (NSMutableArray *)specifiers {
    // 自己的缓存：完全不依赖父类 ivar 的偏移量
    NSMutableArray *mine = objc_getAssociatedObject(self, kSBMSpecsKey);
    if ([mine isKindOfClass:NSMutableArray.class] && mine.count) return mine;

    NSMutableArray *s = nil;
    @try {
        s = [self sbm_buildSpecifiers];
    } @catch (__unused NSException *e) {
        s = [NSMutableArray array];
    }
    if (!s) s = [NSMutableArray array];

    objc_setAssociatedObject(self, kSBMSpecsKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 交给父类保管：走真实 setter（或 KVC 兜底写 ivar），不使用编译期偏移
    @try { [self setValue:s forKey:@"specifiers"]; } @catch (__unused NSException *e) {}
    return s;
}

#pragma mark - 刷新

// 只重载滑块那几行：不会打断手势，也避开了整表重建
- (void)sbm_refreshSliderCells {
    NSMutableArray *mine = objc_getAssociatedObject(self, kSBMSpecsKey);
    if (![mine isKindOfClass:NSMutableArray.class]) return;
    if (![self respondsToSelector:@selector(reloadSpecifier:animated:)]) return;
    for (PSSpecifier *sp in mine) {
        if (![sp propertyForKey:@"sbmIsOffset"]) continue;
        @try { [self reloadSpecifier:sp animated:NO]; } @catch (__unused NSException *e) {}
    }
}

- (void)sbm_rebuild {
    // 重新构建一份并整体替换：绝不把数组置空后又让父类保留旧指针
    NSMutableArray *fresh = nil;
    @try { fresh = [self sbm_buildSpecifiers]; } @catch (__unused NSException *e) {}
    if (!fresh) fresh = [NSMutableArray array];
    objc_setAssociatedObject(self, kSBMSpecsKey, fresh, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try { [self setValue:fresh forKey:@"specifiers"]; } @catch (__unused NSException *e) {}
    if ([self respondsToSelector:@selector(reloadSpecifiers)])
        @try { [self reloadSpecifiers]; } @catch (__unused NSException *e) {}
    [self sbm_installPreview];
}

#pragma mark - 按钮

- (void)sbm_resetAll {
    NSArray *items = SBMDiscoveredItems();
    SBMClearAllOffsets(items);
    for (NSString *cat in SBMCategoryOrder()) {
        NSString *k = SBMKeyForCategory(items, cat, NULL);
        if (!k.length) continue;
        SBMSetOffset(k, @"x", 0, NO);
        SBMSetOffset(k, @"y", 0, NO);
    }
    [self sbm_flushNow];
    [self sbm_rebuild];
}

- (void)sbm_respring {
    [self sbm_flushNow];
    SBMRespring();
}

#pragma mark - SBMPreviewViewDelegate

- (void)previewDidFinishDragging:(SBMPreviewView *)view {
    [self sbm_flushNow];
    [self sbm_refreshSliderCells];
}

@end
