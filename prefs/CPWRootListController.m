//
//  CPWRootListController.m — CarPlayWalls 设置页
//
//  页面结构：
//    开关       → 启用 / 诊断模式
//    外观模式   → 跟随车机日夜 / 恒浅色 / 恒深色
//    浅色壁纸   → 相册选图（PHPicker，免相册权限）+ 当前文件信息
//    深色壁纸   → 同上
//    高级       → 深色图自动生成、激进兜底、查看诊断
//
//  稳定性约定（沿用 StatusBarMover 踩过的坑）：
//    · 绝不直接读写父类 _specifiers 实例变量，整体构建新数组后交给父类
//    · 所有私有 API / 条目构建都包 @try，异常只降级不闪退
//    · 不在 viewWillAppear 里 reloadSpecifiers
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreFoundation/CoreFoundation.h>

extern int notify_post(const char *name);

static NSString *const kAppID  = @"com.minis.carplaywalls";
static NSString *const kDir    = @"/var/mobile/Library/CarPlayWalls";
static NSString *const kDump   = @"/var/mobile/Library/Preferences/com.minis.carplaywalls.dump.plist";
static NSString *const kNotify = @"com.minis.carplaywalls/changed";

@interface CPWRootListController : PSListController <PHPickerViewControllerDelegate>
@end

// 补声明：开发头文件里未必出现的私有方法
@interface PSListController (CPWPrivate)
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

// ---------------------------------------------------------------- 配置读写
static id CPWPref(NSString *key, id def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kAppID);
    if (v) return (__bridge_transfer id)v;
    return def;
}

static NSString *CPWPathPref(NSString *key, NSString *def) {
    id v = CPWPref(key, def);
    if ([v isKindOfClass:NSString.class] && [v length] > 0) return v;
    return def;
}

@implementation CPWRootListController {
    NSInteger _pickTarget;   // 0 = 浅色, 1 = 深色
    BOOL      _picking;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CarPlay 壁纸";
}

- (NSString *)lightPath { return CPWPathPref(@"lightPath", [kDir stringByAppendingPathComponent:@"light.jpg"]); }
- (NSString *)darkPath  { return CPWPathPref(@"darkPath",  [kDir stringByAppendingPathComponent:@"dark.jpg"]); }

#pragma mark - 条目工厂

- (PSSpecifier *)cpw_switch:(NSString *)title key:(NSString *)key def:(BOOL)def {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:nil
                                                       cell:PSSwitchCell
                                                       edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:kAppID forKey:@"defaults"];
    [sp setProperty:@(def) forKey:@"default"];
    return sp;
}

- (PSSpecifier *)cpw_button:(NSString *)title action:(SEL)action {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
                                                     target:self
                                                        set:nil
                                                        get:nil
                                                     detail:nil
                                                       cell:PSButtonCell
                                                       edit:nil];
    @try { [sp setButtonAction:action]; } @catch (__unused NSException *e) {}
    return sp;
}

- (PSSpecifier *)cpw_group:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:name];
    if (footer.length) [g setProperty:footer forKey:@"footerText"];
    return g;
}

// 当前文件信息（文件名 · 分辨率 · 体积）
- (NSString *)cpw_fileInfo:(NSString *)path {
    @try {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if (!attr) return [NSString stringWithFormat:@"尚未设置 · 期望路径 %@", path];
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        NSString *dims = @"?";
        if (img) dims = [NSString stringWithFormat:@"%.0f×%.0f", img.size.width * img.scale, img.size.height * img.scale];
        return [NSString stringWithFormat:@"当前：%@ · %@ · %.1f MB", path.lastPathComponent, dims,
                [attr[NSFileSize] doubleValue] / 1024.0 / 1024.0];
    } @catch (__unused NSException *e) { return path; }
}

#pragma mark - 页面构建

- (NSArray *)specifiers {
    NSMutableArray *arr = [NSMutableArray array];
    @try {
        // ---- 开关 ----
        [arr addObject:[self cpw_group:@"开关"
                                footer:@"关闭后立刻恢复系统自带壁纸。安装后若车机出现异常，也可以在 Filza 里新建空文件 /var/mobile/Library/Preferences/com.minis.carplaywalls.disable 强制关停。"]];
        [arr addObject:[self cpw_switch:@"启用自定义壁纸" key:@"enabled" def:YES]];
        [arr addObject:[self cpw_switch:@"诊断模式" key:@"diagnostics" def:NO]];

        // ---- 外观模式 ----
        [arr addObject:[self cpw_group:@"外观模式"
                                footer:@"「跟随车机日夜」= 车机切到夜间（或手机进入深色）时自动换深色图。"]];
        PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:@"模式"
                                                           target:self
                                                              set:@selector(setPreferenceValue:specifier:)
                                                              get:@selector(readPreferenceValue:)
                                                           detail:NSClassFromString(@"PSListItemsController")
                                                             cell:PSLinkListCell
                                                             edit:nil];
        [mode setProperty:@"mode" forKey:@"key"];
        [mode setProperty:kAppID forKey:@"defaults"];
        [mode setProperty:@0 forKey:@"default"];
        [mode setProperty:@[@"跟随车机日夜", @"始终用浅色图", @"始终用深色图"] forKey:@"validTitles"];
        [mode setProperty:@[@0, @1, @2] forKey:@"validValues"];
        [arr addObject:mode];

        // ---- 浅色壁纸 ----
        [arr addObject:[self cpw_group:@"浅色壁纸" footer:[self cpw_fileInfo:[self lightPath]]]];
        [arr addObject:[self cpw_button:@"从相册选择浅色壁纸" action:@selector(cpw_pickLight:)]];

        // ---- 深色壁纸 ----
        [arr addObject:[self cpw_group:@"深色壁纸" footer:[self cpw_fileInfo:[self darkPath]]]];
        [arr addObject:[self cpw_button:@"从相册选择深色壁纸" action:@selector(cpw_pickDark:)]];

        // ---- 高级 ----
        [arr addObject:[self cpw_group:@"高级"
                                footer:@"深色图缺失时会用「浅色图整体压暗 45%」自动生成一张。\n「激进兜底」会额外替换任何占满屏幕、层级最靠底的大图，仅在主方案不生效时打开。"]];
        [arr addObject:[self cpw_switch:@"深色图自动生成" key:@"autoDerive" def:YES]];
        [arr addObject:[self cpw_switch:@"激进兜底（大背景图）" key:@"generic" def:NO]];
        [arr addObject:[self cpw_button:@"查看诊断结果" action:@selector(cpw_showDiagnostics:)]];

        // ---- 说明 ----
        [arr addObject:[self cpw_group:@"使用说明"
                                footer:[NSString stringWithFormat:
                                        @"1. 选好图片后，重新连接车机（或在车里切换一次日夜模式）即可看到新壁纸。\n"
                                        @"2. 建议图片比例与车机屏幕一致（如 1920×720、800×480），避免被拉伸。\n"
                                        @"3. 也可以不用相册，直接用 Filza 把图片放到 %@ 下的 light.jpg / dark.jpg。\n"
                                        @"4. 换图后无需重启车机，系统会在下一次取图时读到新文件。", kDir]]];
    } @catch (__unused NSException *e) {}
    return arr;
}

#pragma mark - 相册选图

- (void)cpw_pickLight:(PSSpecifier *)sp { [self cpw_presentPicker:0]; }
- (void)cpw_pickDark:(PSSpecifier *)sp  { [self cpw_presentPicker:1]; }

- (void)cpw_presentPicker:(NSInteger)target {
    if (_picking) return;
    if (self.presentedViewController) return;
    @try {
        if (@available(iOS 14.0, *)) {
            _pickTarget = target;
            PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];   // 免相册权限
            cfg.selectionLimit = 1;
            cfg.filter = [PHPickerFilter imagesFilter];
            PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
            vc.delegate = self;
            _picking = YES;
            [self presentViewController:vc animated:YES completion:nil];
        } else {
            [self cpw_alert:@"系统版本过低" msg:@"本插件需要 iOS 14+ 的相册选择器。请改用 Filza 把图片复制到 /var/mobile/Library/CarPlayWalls/ 下。"];
        }
    } @catch (__unused NSException *e) {
        _picking = NO;
        [self cpw_alert:@"打开相册失败" msg:@"可以改用 Filza 手动放置图片。"];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    _picking = NO;
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    @try {
        NSItemProvider *provider = results.firstObject.itemProvider;
        if (!provider || ![provider canLoadObjectOfClass:UIImage.class]) {
            [self cpw_alert:@"读取图片失败" msg:@"这张图片无法作为壁纸使用，换一张试试。"];
            return;
        }
        NSInteger target = _pickTarget;
        __weak __typeof(self) weakSelf = self;
        [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> obj, NSError *error) {
            UIImage *img = [obj isKindOfClass:UIImage.class] ? (UIImage *)obj : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong __typeof(weakSelf) self = weakSelf;
                if (!self) return;
                if (img) [self cpw_saveImage:img target:target];
                else [self cpw_alert:@"读取图片失败" msg:error.localizedDescription ?: @""];
            });
        }];
    } @catch (__unused NSException *e) {
        [self cpw_alert:@"读取图片失败" msg:@"请换一张图片重试。"];
    }
}

#pragma mark - 保存

- (void)cpw_saveImage:(UIImage *)image target:(NSInteger)target {
    @try {
        NSString *path = [kDir stringByAppendingPathComponent:(target == 1 ? @"dark.jpg" : @"light.jpg")];
        UIImage *out  = [self cpw_downscale:image maxSide:3840];
        NSData  *data = UIImageJPEGRepresentation(out, 0.92);
        if (!data) {
            [self cpw_alert:@"保存失败" msg:@"图片编码失败，请换一张。"];
            return;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:NULL];
        if (![data writeToFile:path atomically:YES]) {
            [self cpw_alert:@"保存失败" msg:[NSString stringWithFormat:@"无法写入 %@", path]];
            return;
        }
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0644} ofItemAtPath:path error:NULL];

        // 记进配置（tweak 端每秒读一次这个文件）
        NSString *key = (target == 1) ? @"darkPath" : @"lightPath";
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)path, (__bridge CFStringRef)kAppID);
        CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)@YES, (__bridge CFStringRef)kAppID);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);
        notify_post(kNotify.UTF8String);

        NSString *dims = [NSString stringWithFormat:@"%.0f×%.0f", out.size.width, out.size.height];
        [self cpw_alert:(target == 1 ? @"深色壁纸已保存" : @"浅色壁纸已保存")
                    msg:[NSString stringWithFormat:@"%@（%@，%.1f MB）\n\n重新连接车机、或在车里切换一次日夜模式即可看到。",
                         path.lastPathComponent, dims, data.length / 1024.0 / 1024.0]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { [self reloadSpecifiers]; } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {
        [self cpw_alert:@"保存失败" msg:@"发生异常，请改用 Filza 手动放置图片。"];
    }
}

// 超大图等比缩小，避免每帧解码几千万像素
- (UIImage *)cpw_downscale:(UIImage *)image maxSide:(CGFloat)maxSide {
    CGFloat scale = image.scale > 0 ? image.scale : 1.0;
    CGFloat w = image.size.width * scale, h = image.size.height * scale;
    if (w <= 0 || h <= 0) return image;
    if (MAX(w, h) <= maxSide) return image;
    CGFloat r = maxSide / MAX(w, h);
    CGSize n = CGSizeMake(floor(w * r), floor(h * r));
    UIGraphicsBeginImageContextWithOptions(n, YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, n.width, n.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: image;
}

#pragma mark - 诊断

- (void)cpw_showDiagnostics:(PSSpecifier *)sp {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kDump];
        if (![d isKindOfClass:NSDictionary.class]) {
            [self cpw_alert:@"还没有诊断数据"
                         msg:@"诊断数据由车机侧进程写入。请先把「诊断模式」打开，连上车机跑一会儿，再回来看。"];
            return;
        }
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"进程：%@\n", d[@"host"] ?: @"?"];
        [s appendFormat:@"CRSUIWallpaper：%@\n", [d[@"crsuiWallpaper"] boolValue] ? @"已找到" : @"未找到"];
        [s appendFormat:@"浅色图：%@／深色图：%@\n", [d[@"lightFound"] boolValue] ? @"有" : @"无",
                                                     [d[@"darkFound"] boolValue] ? @"有" : @"无"];
        NSDictionary *hits = d[@"hits"];
        if ([hits isKindOfClass:NSDictionary.class] && hits.count) {
            [s appendString:@"\n命中记录：\n"];
            for (NSString *k in hits) {
                [s appendFormat:@"· %@ × %@\n", k, hits[k]];
            }
        }
        NSArray *wp = d[@"wallpaperClasses"];
        if ([wp isKindOfClass:NSArray.class] && wp.count) {
            [s appendFormat:@"\n运行时壁纸相关类（%lu）：\n", (unsigned long)wp.count];
            NSInteger n = MIN((NSInteger)wp.count, 6);
            for (NSInteger i = 0; i < n; i++) [s appendFormat:@"· %@\n", wp[i]];
        }
        [self cpw_alert:@"CarPlayWalls 诊断" msg:s];
    } @catch (__unused NSException *e) {}
}

#pragma mark - 工具

- (void)cpw_alert:(NSString *)title msg:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                        message:msg
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            UIViewController *top = self;
            while (top.presentedViewController) top = top.presentedViewController;
            [top presentViewController:ac animated:YES completion:nil];
        } @catch (__unused NSException *e) {}
    });
}

@end
