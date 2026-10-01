//
//  CPWInject.xm — 把「CarPlay 壁纸」入口注入「设置」App
//
//  ★ 为什么这么绕：
//    PreferenceLoader 2.x 源码里写死了 `entry` 键检查，没有 entry 的纯 plist
//    页面不会被注册；而带 entry 的代码 bundle 需要 Preferences 去 dlopen 我们的
//    二进制，在 XinaA15 / iOS 15.4.1 上这条路径会在 dyld 映射镜像、libobjc
//    readClass 阶段 SIGBUS。
//    「被越狱注入器注入」这条路径则是正常的，所以设置界面直接编进一个只注入
//    com.apple.Preferences 的 dylib，彻底绕开 dlopen。
//
//  本 dylib 只在「设置」进程里存在，链接 Preferences.framework 不会影响
//  SpringBoard / CarPlayApp（那边用的是另一个 dylib）。
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// 定义在 CPWRootListController.m（同一个 dylib 内）
@interface CPWRootListController : PSListController @end

static NSString *const kCPWRowName = @"CarPlay 壁纸";

// 只在「设置」进程、且是根列表控制器时动手
static BOOL CPWSettingsRootController(id self) {
    @try {
        static NSString *bid = nil;
        if (!bid) bid = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"";
        if (![bid isEqualToString:@"com.apple.Preferences"]) return NO;
        if ([self parentController] != nil) return NO;   // 只加在根列表
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

%hook PSListController

- (NSMutableArray *)specifiers {
    NSMutableArray *orig = %orig;
    @try {
        if (!CPWSettingsRootController(self)) return orig;
        if (![orig isKindOfClass:NSMutableArray.class]) return orig;

        for (PSSpecifier *sp in orig) {
            if ([[sp name] isEqualToString:kCPWRowName]) return orig;   // 已经加过
        }

        NSMutableArray *arr = [NSMutableArray arrayWithArray:orig];
        [arr addObject:[PSSpecifier emptyGroupSpecifier]];

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:kCPWRowName
                                                         target:self
                                                            set:nil
                                                            get:nil
                                                         detail:NSClassFromString(@"CPWRootListController")
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
