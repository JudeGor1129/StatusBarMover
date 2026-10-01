//
//  SBMInject.xm — 把设置入口直接注入「设置」App
//
//  ★ 为什么不走 PreferenceLoader bundle：
//    本环境（XinaA15 / iOS 15.4.1）下，Preferences 用 NSBundle/dlopen 加载任何
//    自定义二进制都会在 dyld 映射镜像、libobjc readClass 阶段 SIGBUS
//    （arm64e 切片强制 chained fixups，该环境处理不了；又不能退回 arm64，
//     因为系统 App 进程只接受 arm64e）。
//    而「被越狱注入器(jbinjector)注入」这条路径是好的 —— 所以把设置界面
//    直接编进一个只注入 com.apple.Preferences 的 dylib，完全绕开 dlopen。
//
//  这个 dylib 只在「设置」进程里存在，链接 Preferences.framework 不会影响
//  SpringBoard（那边用的是另一个 dylib）。
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// 定义在 SBMRootListController.m（同一个 dylib 内）
@interface SBMRootListController : PSListController @end

static NSString *const kSBMRowName = @"状态栏图标位置";

// 只在「设置」进程、且是根列表控制器时动手
static BOOL SBMSettingsRootController(id self) {
    @try {
        static NSString *bid = nil;
        if (!bid) bid = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"";
        if (![bid isEqualToString:@"com.apple.Preferences"]) return NO;
        if ([self parentController] != nil) return NO;
        Class cls = NSClassFromString(@"_SBMSettingsRootProbe");
        (void)cls;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

%hook PSListController

- (NSMutableArray *)specifiers {
    NSMutableArray *orig = %orig;
    @try {
        if (!SBMSettingsRootController(self)) return orig;
        if (![orig isKindOfClass:NSMutableArray.class]) return orig;

        // 已经加过就不重复添加
        for (PSSpecifier *sp in orig) {
            if ([[sp name] isEqualToString:kSBMRowName]) return orig;
        }

        NSMutableArray *arr = [NSMutableArray arrayWithArray:orig];
        [arr addObject:[PSSpecifier emptyGroupSpecifier]];

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:kSBMRowName
                                                         target:self
                                                            set:nil
                                                            get:nil
                                                         detail:NSClassFromString(@"SBMRootListController")
                                                           cell:PSLinkCell
                                                           edit:nil];
        if (row) {
            [row setProperty:@YES forKey:@"enabled"];
            [arr addObject:row];
        }
        return arr;
    } @catch (__unused NSException *e) {
        return orig;
    }
}

%end
