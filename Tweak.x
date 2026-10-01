// =============================================================================
//  CarPlayWalls — 为 CarPlay 的「浅色 / 深色（日夜）」模式分别设置自定义壁纸
//  v1.0.0  ·  iOS 15.x rootless (XinaA15 / xina2)
//
//  原理（已由 iOS 14/15/16/17 头文件与第三方实现交叉验证）：
//    CarPlay 桌面壳 App（bundle id = com.apple.CarPlayApp）在绘制桌面壁纸时，
//    会调用 CarPlayUIServices.framework 里的私有类：
//
//        CRSUIWallpaperPreferences.defaultWallpaper  ->  CRSUIWallpaper 实例
//        [CRSUIWallpaper wallpaperImageCompatibleWithTraitCollection:tc]
//
//    该方法返回的就是「当前外观（浅/深）对应的壁纸 UIImage」——
//    traitCollection.userInterfaceStyle 正是车机日夜模式，因此这里就是
//    「浅色/深色分别换壁纸」的唯一正确 Hook 点。
//
//  安全性：
//    · 只替换「方法返回值」，不碰任何布局 / frame / 视图层级 → 无 watchdog 风险
//    · 任何异常都被 @try 吞掉，最坏情况=退回系统原图
//    · POSIX 紧急开关：/var/mobile/Library/Preferences/com.minis.carplaywalls.disable
// =============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>

// ------------------------------------------------------------------ 路径常量
static NSString * const kPrefsPath = @"/var/mobile/Library/Preferences/com.minis.carplaywalls.plist";
static NSString * const kDumpPath  = @"/var/mobile/Library/Preferences/com.minis.carplaywalls.dump.plist";
static NSString * const kKillPath  = @"/var/mobile/Library/Preferences/com.minis.carplaywalls.disable";
static NSString * const kImageDir  = @"/var/mobile/Library/CarPlayWalls";
static NSString * const kFWPath    = @"/System/Library/PrivateFrameworks/CarPlayUIServices.framework/CarPlayUIServices";

#define CPW_VERSION @"1.0.0"

// ------------------------------------------------------------------ 全局配置
static BOOL       gEnabled     = YES;   // 总开关
static BOOL       gDiagnostics = NO;    // 诊断模式（写 dump plist）
static BOOL       gAutoDerive  = YES;   // 深色图缺失时由浅色图自动压暗生成
static BOOL       gGeneric     = NO;    // 激进兜底：命名不含 Wallpaper 的大背景视图也替换
static NSInteger  gMode        = 0;     // 0 = 跟随车机日夜, 1 = 恒用浅色图, 2 = 恒用深色图
static NSString  *gLightPath   = nil;
static NSString  *gDarkPath    = nil;

static NSTimeInterval gLastCfgCheck = -1e9;
static BOOL gInstalled = NO;

static NSMutableDictionary *gImgCache   = nil;  // path        -> UIImage
static NSMutableDictionary *gImgCacheMt = nil;  // path        -> mtime(NSNumber)
static NSMutableDictionary *gHitCount   = nil;  // selector    -> NSNumber
static NSMutableArray      *gLogLines   = nil;  // 最近若干条调用记录
static NSMutableArray      *gWpClasses  = nil;  // 运行时所有含 Wallpaper 的类名

#pragma mark - 配置读取

// 读 plist 配置（只有值发生变化才写全局变量）
static void CPWReloadConfig(void) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
        if (d) {
            if (d[@"enabled"])     gEnabled     = [d[@"enabled"] boolValue];
            if (d[@"diagnostics"]) gDiagnostics = [d[@"diagnostics"] boolValue];
            if (d[@"autoDerive"])  gAutoDerive  = [d[@"autoDerive"] boolValue];
            if (d[@"generic"])     gGeneric     = [d[@"generic"] boolValue];
            if (d[@"mode"])        gMode        = [d[@"mode"] integerValue];
            NSString *l = d[@"lightPath"], *k = d[@"darkPath"];
            gLightPath = [l isKindOfClass:[NSString class]] && l.length ? l : [kImageDir stringByAppendingPathComponent:@"light.png"];
            gDarkPath  = [k isKindOfClass:[NSString class]] && k.length ? k : [kImageDir stringByAppendingPathComponent:@"dark.png"];
        } else {
            gLightPath = [kImageDir stringByAppendingPathComponent:@"light.png"];
            gDarkPath  = [kImageDir stringByAppendingPathComponent:@"dark.png"];
        }
    } @catch (__unused NSException *e) {}
}

// 节流：每秒最多碰一次文件系统
static void CPWMaybeReloadConfig(void) {
    NSTimeInterval now = CACurrentMediaTime();
    if (now - gLastCfgCheck < 1.0) return;
    gLastCfgCheck = now;
    CPWReloadConfig();
}

// 总闸：开关 / 紧急关停文件 / 诊断
static BOOL CPWEnabled(void) {
    CPWMaybeReloadConfig();
    if (!gEnabled) return NO;
    static NSTimeInterval lastKillCheck = -1e9;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - lastKillCheck > 2.0) {
        lastKillCheck = now;
        if ([[NSFileManager defaultManager] fileExistsAtPath:kKillPath]) return NO;
    }
    return YES;
}

#pragma mark - 图片装载与变换

// 按路径读取图片，带 mtime 缓存（换图后下次读取自动生效，无需 respring）
static UIImage *CPWImageAtPath(NSString *path) {
    if (path.length == 0) return nil;
    @try {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if (!attr) return nil;
        NSTimeInterval mt = [attr fileModificationDate].timeIntervalSince1970;
        NSNumber *cached = gImgCacheMt[path];
        if (cached && gImgCache[path] && fabs(cached.doubleValue - mt) < 0.001) return gImgCache[path];
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) {
            gImgCacheMt[path] = @(mt);
            gImgCache[path]   = img;
        }
        return img;
    } @catch (__unused NSException *e) { return nil; }
}

// 用户配置的路径不存在时，在壁纸目录里按 light.* / dark.* 自动兜底查找
static NSString *CPWResolvePath(NSString *configured, NSString *stem) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:configured]) return configured;
    @try {
        NSArray *list = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kImageDir error:NULL];
        for (NSString *name in list) {
            if ([[name lowercaseString] hasPrefix:stem]) {
                return [kImageDir stringByAppendingPathComponent:name];
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// 浅色图 → 深色图：整体压暗（只有浅色图时也能用）
static UIImage *CPWDeriveDark(UIImage *light) {
    if (!light) return nil;
    @try {
        UIGraphicsBeginImageContextWithOptions(light.size, YES, light.scale);
        [light drawInRect:CGRectMake(0, 0, light.size.width, light.size.height)];
        [[[UIColor blackColor] colorWithAlphaComponent:0.45] setFill];
        UIRectFillUsingBlendMode(CGRectMake(0, 0, light.size.width, light.size.height), kCGBlendModeNormal);
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return out;
    } @catch (__unused NSException *e) { return light; }
}

// 核心：按外观样式取自定义壁纸
static UIImage *CPWImageForStyle(UIUserInterfaceStyle style) {
    @try {
        NSString *lightPath = CPWResolvePath(gLightPath, @"light");
        NSString *darkPath  = CPWResolvePath(gDarkPath,  @"dark");
        UIImage  *light = CPWImageAtPath(lightPath);
        UIImage  *dark  = CPWImageAtPath(darkPath);

        BOOL wantDark;
        if (gMode == 1)      wantDark = NO;
        else if (gMode == 2) wantDark = YES;
        else                 wantDark = (style == UIUserInterfaceStyleDark);

        if (wantDark) {
            if (dark) return dark;
            if (gAutoDerive && light) return CPWDeriveDark(light);
            return light;
        }
        if (light) return light;
        return dark;
    } @catch (__unused NSException *e) { return nil; }
}

#pragma mark - 诊断

static void CPWNote(NSString *what, NSInteger style, BOOL substituted) {
    if (!gDiagnostics) return;
    @try {
        if (!gLogLines)   gLogLines = [NSMutableArray array];
        if (!gHitCount)   gHitCount = [NSMutableDictionary dictionary];
        gHitCount[what] = @([gHitCount[what] integerValue] + 1);
        if (gLogLines.count > 60) [gLogLines removeObjectAtIndex:0];
        [gLogLines addObject:@{
            @"t"    : @([[NSDate date] timeIntervalSince1970]),
            @"what" : what,
            @"style": @(style),
            @"sub"  : substituted ? @YES : @NO,
        }];

        static NSTimeInterval lastDump = -1e9;
        NSTimeInterval now = CACurrentMediaTime();
        if (now - lastDump < 1.0) return;
        lastDump = now;

        if (!gWpClasses) {
            NSMutableArray *arr = [NSMutableArray array];
            unsigned int n = 0;
            Class *cs = objc_copyClassList(&n);
            for (unsigned int i = 0; i < n; i++) {
                const char *nm = class_getName(cs[i]);
                if (nm && strcasestr(nm, "wallpaper")) [arr addObject:[NSString stringWithUTF8String:nm]];
            }
            if (cs) free(cs);
            gWpClasses = arr;
        }

        NSDictionary *dump = @{
            @"version"        : CPW_VERSION,
            @"host"           : [[NSBundle mainBundle] bundleIdentifier] ?: @"?",
            @"enabled"        : @(gEnabled),
            @"mode"           : @(gMode),
            @"lightPath"      : gLightPath ?: @"",
            @"darkPath"       : gDarkPath ?: @"",
            @"lightFound"     : @(CPWResolvePath(gLightPath, @"light") != nil),
            @"darkFound"      : @(CPWResolvePath(gDarkPath, @"dark") != nil),
            @"crsuiWallpaper" : @(objc_getClass("CRSUIWallpaper") != NULL),
            @"crsuiPrefs"     : @(objc_getClass("CRSUIWallpaperPreferences") != NULL),
            @"wallpaperClasses": gWpClasses,
            @"hits"           : gHitCount,
            @"recent"         : gLogLines,
        };
        [dump writeToFile:kDumpPath atomically:YES];
    } @catch (__unused NSException *e) {}
}

#pragma mark - CRSUIWallpaper 动态 Hook（手工 swizzle，不依赖 Logos 的初始化时机）

static IMP gOrigWPImage    = NULL;  // -wallpaperImageCompatibleWithTraitCollection:
static IMP gOrigWPThumb    = NULL;  // -thumbnailImageCompatibleWithTraitCollection:
static IMP gOrigWPSupports = NULL;  // -supportsDynamicAppearance

static UIImage *CPWWPImage(id self, SEL _cmd, UITraitCollection *tc) {
    UIImage *orig = gOrigWPImage ? ((UIImage *(*)(id, SEL, id))gOrigWPImage)(self, _cmd, tc) : nil;
    if (CPWEnabled()) {
        UIImage *mine = CPWImageForStyle(tc ? tc.userInterfaceStyle : UIUserInterfaceStyleLight);
        if (mine) {
            CPWNote(@"CRSUIWallpaper.wallpaperImageForTraits", tc ? tc.userInterfaceStyle : -1, YES);
            return mine;
        }
    }
    CPWNote(@"CRSUIWallpaper.wallpaperImageForTraits", tc ? tc.userInterfaceStyle : -1, NO);
    return orig;
}

static UIImage *CPWWPThumb(id self, SEL _cmd, UITraitCollection *tc) {
    UIImage *orig = gOrigWPThumb ? ((UIImage *(*)(id, SEL, id))gOrigWPThumb)(self, _cmd, tc) : nil;
    if (CPWEnabled()) {
        UIImage *mine = CPWImageForStyle(tc ? tc.userInterfaceStyle : UIUserInterfaceStyleLight);
        if (mine) {
            CPWNote(@"CRSUIWallpaper.thumbnailImageForTraits", tc ? tc.userInterfaceStyle : -1, YES);
            return mine;
        }
    }
    return orig;
}

static BOOL CPWWPSupports(id self, SEL _cmd) {
    if (CPWEnabled()) return YES;   // 声明支持动态外观，确保系统会按日夜重新取图
    return gOrigWPSupports ? ((BOOL (*)(id, SEL))gOrigWPSupports)(self, _cmd) : YES;
}

// 安装 Hook（幂等；类还没加载就 dlopen 一次私有框架）
static void CPWTryInstall(void) {
    if (gInstalled) return;
    @try {
        Class c = objc_getClass("CRSUIWallpaper");
        if (!c) {
            dlopen([kFWPath UTF8String], RTLD_LAZY);
            c = objc_getClass("CRSUIWallpaper");
        }
        if (!c) return;

        Method m;
        m = class_getInstanceMethod(c, NSSelectorFromString(@"wallpaperImageCompatibleWithTraitCollection:"));
        if (m && gOrigWPImage == NULL) gOrigWPImage = method_setImplementation(m, (IMP)CPWWPImage);

        m = class_getInstanceMethod(c, NSSelectorFromString(@"thumbnailImageCompatibleWithTraitCollection:"));
        if (m && gOrigWPThumb == NULL) gOrigWPThumb = method_setImplementation(m, (IMP)CPWWPThumb);

        m = class_getInstanceMethod(c, NSSelectorFromString(@"supportsDynamicAppearance"));
        if (m && gOrigWPSupports == NULL) gOrigWPSupports = method_setImplementation(m, (IMP)CPWWPSupports);

        if (gOrigWPImage || gOrigWPThumb) {
            gInstalled = YES;
            CPWNote(@"installed.CRSUIWallpaper", 0, NO);
        }
    } @catch (__unused NSException *e) {}
}

// 早期反复重试：UI 起来的过程中最多尝试 ~20 次
static void CPWScheduleInstall(void) {
    if (gInstalled) return;
    CPWTryInstall();
    if (gInstalled) return;
    static int tries = 0;
    if (tries++ >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CPWScheduleInstall();
    });
}

#pragma mark - 兜底：命名的 Wallpaper 视图（不同 iOS 版本可能直接贴图）

// 视图类名链里只要出现 Wallpaper，就认为它是壁纸视图
static BOOL CPWViewLooksLikeWallpaper(UIView *v) {
    int depth = 0;
    for (UIView *s = v; s && depth < 5; s = s.superview, depth++) {
        @try {
            NSString *cn = NSStringFromClass([s class]);
            if ([cn rangeOfString:@"Wallpaper" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

// 激进模式：占屏面积达到六成以上、且层级最靠底的大图也认作壁纸
static BOOL CPWViewIsBigBackground(UIImageView *v) {
    @try {
        CGRect f = v.frame;
        UIView *sup = v.superview;
        if (!sup) return NO;
        CGSize s = sup.bounds.size;
        if (s.width < 10 || s.height < 10) return NO;
        if (f.size.width * f.size.height < s.width * s.height * 0.6) return NO;
        if (sup.subviews.count && sup.subviews[0] != v) return NO;
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}

#pragma mark - Logos Hooks

%hook UIImageView

- (void)setImage:(UIImage *)image {
    // 顺便推进 CRSUIWallpaper 的安装（收到第一张图时私有类通常已加载）
    if (!gInstalled) CPWTryInstall();

    if (image && CPWEnabled()) {
        BOOL target = gGeneric ? CPWViewIsBigBackground(self) : CPWViewLooksLikeWallpaper(self);
        if (target) {
            UIImage *mine = CPWImageForStyle(self.traitCollection.userInterfaceStyle);
            if (mine) image = mine;
            if (gDiagnostics) CPWNote([NSString stringWithFormat:@"IMGVIEW.%@", NSStringFromClass([self class])],
                                      self.traitCollection.userInterfaceStyle, mine != nil);
        } else if (gDiagnostics) {
            CPWNote([NSString stringWithFormat:@"UIImageView.setImage(%@)", NSStringFromClass([self class])],
                    self.traitCollection.userInterfaceStyle, NO);
        }
    }
    %orig(image);
}

%end

%hook UIImage

// 仅诊断：记录疑似壁纸资源名，用于确认 iOS 15 的真实取图路径
+ (UIImage *)imageNamed:(NSString *)name {
    UIImage *img = %orig(name);
    if (gDiagnostics && name.length) {
        @try {
            if ([name rangeOfString:@"wall" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [name hasSuffix:@"-Light"] || [name hasSuffix:@"-Dark"]) {
                CPWNote([NSString stringWithFormat:@"imageNamed(%@)", name], -1, NO);
            }
        } @catch (__unused NSException *e) {}
    }
    return img;
}

%end

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    CPWScheduleInstall();
}

%end

// ---------------------------------------------------------------------------
// 构造函数交给 Logos 自动生成。
// 注意两点（都踩过）：
//   1. 不要手写自定义构造函数——新版 Logos 会报
//      "does not make sense outside a block"；
//   2. Logos 的预处理会扫描原始文本，**注释里出现那些百分号指令同样会报错**，
//      所以本文件注释里一律不写这类指令。
// ---------------------------------------------------------------------------
