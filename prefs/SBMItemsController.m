//
//  SBMItemsController.m — 「全部图标（高级）」页
//
//  列出插件在本机实测发现的所有状态栏图标，每个都可以单独设定 X / Y 偏移。
//  主页面负责常用的六个；这一页保证任何图标都不会「够不着」。
//

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "SBMCommon.h"

@interface SBMItemsController : PSListController
@end

@implementation SBMItemsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"全部图标";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)SBMAppID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)SBMAppID);
    notify_post(SBMLoadNotif.UTF8String);
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id v = SBMReadRaw(key);
    if ([v isKindOfClass:NSNumber.class]) return v;
    if ([v isKindOfClass:NSString.class]) return @([v doubleValue]);
    return @0;
}

- (PSSpecifier *)sbm_sliderNamed:(NSString *)name key:(NSString *)fullKey axis:(NSString *)axis group:(NSString *)groupKey {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:name
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:nil
                                                       cell:PSSliderCell
                                                       edit:nil];
    [sp setProperty:SBMAppID forKey:@"defaults"];
    [sp setProperty:fullKey forKey:@"key"];
    [sp setProperty:@0 forKey:@"default"];
    [sp setProperty:@([axis isEqualToString:@"x"] ? -60 : -25) forKey:@"minValue"];
    [sp setProperty:@([axis isEqualToString:@"x"] ?  60 :  25) forKey:@"maxValue"];
    [sp setProperty:@YES forKey:@"isContinuous"];
    [sp setProperty:groupKey forKey:@"sbmKey"];
    return sp;
}

- (NSMutableArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *s = [NSMutableArray array];
    NSArray *items = SBMDiscoveredItems();

    PSSpecifier *g0 = [PSSpecifier emptyGroupSpecifier];
    [g0 setProperty:items.count
        ? [NSString stringWithFormat:@"插件在本机共发现 %lu 个状态栏图标。带 cat=signal/data/wifi/battery 的条目就是主页面那六项。",
           (unsigned long)items.count]
        : @"还没有发现任何图标。请开启/关闭一次 Wi-Fi、飞行模式，或重启 SpringBoard 后再回到本页。"
             forKey:@"footerText"];
    [s addObject:g0];

    PSSpecifier *copy = [PSSpecifier preferenceSpecifierNamed:@"复制诊断信息到剪贴板"
                                                       target:self
                                                          set:nil
                                                          get:nil
                                                       detail:nil
                                                         cell:PSButtonCell
                                                         edit:nil];
    [copy setProperty:@YES forKey:@"enabled"];
    [copy setButtonAction:@selector(sbm_copyDiagnostics)];
    [s addObject:copy];

    for (NSDictionary *row in items) {
        NSString *key = row[@"key"];
        NSString *cls = row[@"cls"];
        NSString *cat = row[@"cat"];

        PSSpecifier *grp = [PSSpecifier emptyGroupSpecifier];
        [grp setProperty:SBMNiceName(key, cls) forKey:@"label"];
        [grp setProperty:[NSString stringWithFormat:@"标识符 %@　·　分类 %@　·　%@",
                          key, SBMCategoryTitle(cat), cls.length ? cls : @"—"]
                 forKey:@"footerText"];
        [s addObject:grp];

        [s addObject:[self sbm_sliderNamed:@"水平偏移"
                                       key:[NSString stringWithFormat:@"%@.x", key]
                                      axis:@"x"
                                     group:key]];
        [s addObject:[self sbm_sliderNamed:@"垂直偏移"
                                       key:[NSString stringWithFormat:@"%@.y", key]
                                      axis:@"y"
                                     group:key]];

        PSSpecifier *sum = [PSSpecifier preferenceSpecifierNamed:@"当前数值"
                                                          target:self
                                                             set:nil
                                                             get:@selector(sbm_summary:)
                                                          detail:nil
                                                            cell:PSTitleValueCell
                                                            edit:nil];
        [sum setProperty:key forKey:@"sbmKey"];
        [sum setProperty:@YES forKey:@"sbmSummary"];
        [s addObject:sum];
    }

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

    _specifiers = s;
    return _specifiers;
}

- (id)sbm_summary:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"sbmKey"];
    if (!key.length) return @"";
    return [NSString stringWithFormat:@"水平 %+.0f pt　·　垂直 %+.0f pt",
            SBMOffset(key, @"x"), SBMOffset(key, @"y")];
}

- (void)sbm_copyDiagnostics {
    NSString *text = SBMDiagnostics(SBMDiscoveredItems());
    [UIPasteboard generalPasteboard].string = text;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已复制"
                                                              message:@"标识符清单已复制到剪贴板，可直接发给开发者为你的机型做精确适配。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)sbm_resetAll {
    SBMClearAllOffsets(SBMDiscoveredItems());
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
