//
//  SBMCommon.h — 设置页与插件共用的常量 / 工具函数
//
//  偏好键约定：<identifier>.x 与 <identifier>.y（单位：pt）
//  identifier 是插件在运行时从状态栏视图上自动发现的标识符，
//  例如 wifi / battery / batteryDetail / cellularBars / dataNetwork / timeString。
//  设置页不需要硬编码这些名字 —— 它直接读取插件写下的发现结果。
//

#ifndef SBM_COMMON_H
#define SBM_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>
#import <unistd.h>

static NSString *const SBMAppID     = @"com.minis.statusbarmover";
static NSString *const SBMLoadNotif = @"com.minis.statusbarmover/reload";
static NSString *const SBMItemsFile = @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";

// ---- 偏好读写 --------------------------------------------------------------

static inline id SBMReadRaw(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)SBMAppID);
    return (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)SBMAppID);
}

// 写入偏好。sync=YES 时立刻落盘（另一个进程 SpringBoard 才能读到）。
static inline void SBMWriteRaw(NSString *key, id value, BOOL sync) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)SBMAppID);
    if (sync) CFPreferencesAppSynchronize((__bridge CFStringRef)SBMAppID);
    notify_post(SBMLoadNotif.UTF8String);
}

static inline double SBMOffset(NSString *key, NSString *axis) {
    if (!key) return 0.0;
    id v = SBMReadRaw([NSString stringWithFormat:@"%@.%@", key, axis]);
    if ([v isKindOfClass:NSNumber.class]) return [v doubleValue];
    if ([v isKindOfClass:NSString.class]) return [v doubleValue];  // 兼容 1.x 的文本框写法
    return 0.0;
}

static inline void SBMSetOffset(NSString *key, NSString *axis, double v, BOOL sync) {
    if (!key) return;
    SBMWriteRaw([NSString stringWithFormat:@"%@.%@", key, axis], @(v), sync);
}

static inline void SBMClearAllOffsets(NSArray *discovered) {
    for (NSDictionary *row in discovered) {
        NSString *key = row[@"key"];
        if (![key isKindOfClass:NSString.class]) continue;
        SBMWriteRaw([NSString stringWithFormat:@"%@.x", key], nil, NO);
        SBMWriteRaw([NSString stringWithFormat:@"%@.y", key], nil, NO);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)SBMAppID);
    notify_post(SBMLoadNotif.UTF8String);
}

// ---- 插件写下的「已发现图标」列表 ------------------------------------------

// 返回 @[ @{ @"key":..., @"cls":..., @"cat":... } ]，按 key 排序。
// 同时兼容 1.x 的纯字符串数组格式。
static inline NSArray *SBMDiscoveredItems(void) {
    id raw = [NSArray arrayWithContentsOfFile:SBMItemsFile];
    NSMutableArray *out = [NSMutableArray array];
    if ([raw isKindOfClass:NSArray.class]) {
        for (id e in raw) {
            if ([e isKindOfClass:NSDictionary.class]) {
                NSString *k = e[@"key"];
                if (![k isKindOfClass:NSString.class] || !k.length) continue;
                NSString *cls = [e[@"cls"] isKindOfClass:NSString.class] ? e[@"cls"] : @"";
                NSString *cat = [e[@"cat"] isKindOfClass:NSString.class] ? e[@"cat"] : @"other";
                [out addObject:@{ @"key": k, @"cls": cls, @"cat": cat }];
            } else if ([e isKindOfClass:NSString.class] && [e length]) {
                [out addObject:@{ @"key": e, @"cls": @"", @"cat": @"other" }];
            }
        }
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"key"] caseInsensitiveCompare:b[@"key"]];
    }];
    return out;
}

// 某个分类对应的标识符：优先用插件实测发现的；没发现就用候选预置名。
static inline NSString *SBMKeyForCategory(NSArray *items, NSString *cat, BOOL *detected) {
    for (NSDictionary *row in items)
        if ([row[@"cat"] isEqualToString:cat]) {
            if (detected) *detected = YES;
            return row[@"key"];
        }
    if (detected) *detected = NO;
    NSDictionary *fallback = @{
        @"signal"  : @[ @"cellularBars", @"signal", @"signalStrength" ],
        @"data"    : @[ @"dataNetwork", @"networkType" ],
        @"wifi"    : @[ @"wifi" ],
        @"battery" : @[ @"battery" ],
        @"percent" : @[ @"batteryDetail", @"batteryPercent", @"batteryPercentage" ],
        @"time"    : @[ @"timeString", @"time" ],
    };
    NSArray *cands = fallback[cat];
    for (NSString *c in cands) {
        BOOL clash = NO;
        for (NSDictionary *row in items) if ([row[@"key"] isEqualToString:c]) { clash = YES; break; }
        if (!clash) return c;
    }
    return cands.firstObject;
}

// ---- 展示名 ---------------------------------------------------------------

static inline NSString *SBMCategoryTitle(NSString *cat) {
    NSDictionary *m = @{
        @"signal"  : @"信号",
        @"data"    : @"数据网络",
        @"wifi"    : @"Wi-Fi",
        @"battery" : @"电池",
        @"percent" : @"电量百分比",
        @"time"    : @"时间",
    };
    return m[cat] ?: @"其他";
}

// 分类在列表里的固定顺序
static inline NSArray *SBMCategoryOrder(void) {
    return @[ @"signal", @"data", @"wifi", @"battery", @"percent", @"time" ];
}

// 已知标识符的中文名
static inline NSString *SBMNiceName(NSString *key, NSString *cls) {
    NSDictionary *m = @{
        @"wifi"          : @"Wi-Fi",
        @"battery"       : @"电池",
        @"batteryDetail" : @"电量百分比",
        @"cellularBars"  : @"信号",
        @"rawSignal"     : @"运营商文字",
        @"dataNetwork"   : @"数据网络类型",
        @"timeString"    : @"时间",
        @"bluetooth"     : @"蓝牙",
        @"activity"      : @"活动指示器",
        @"location"      : @"定位箭头",
        @"airplane"      : @"飞行模式",
        @"alarm"         : @"闹钟",
        @"vpn"           : @"VPN",
        @"orientationLock": @"方向锁定",
        @"doNotDisturb"  : @"专注模式",
    };
    NSString *n = m[key];
    if (n) return n;
    if (cls.length) {
        NSString *s = [cls stringByReplacingOccurrencesOfString:@"_UIStatusBar" withString:@""];
        s = [s stringByReplacingOccurrencesOfString:@"View" withString:@""];
        if (s.length) return s;
    }
    return key;
}

// 一行诊断文本，方便把这台设备真实的标识符直接发给我做精确适配
static inline NSString *SBMDiagnostics(NSArray *items) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"StatusBarMover 2.0.0 · 设备标识符清单\n"];
    [s appendFormat:@"机型 %@ · 系统 %@\n", UIDevice.currentDevice.model,
                   UIDevice.currentDevice.systemVersion];
    [s appendFormat:@"共发现 %lu 个图标：\n", (unsigned long)items.count];
    for (NSDictionary *row in items)
        [s appendFormat:@"  %-18s cat=%-8s %s\n",
             [row[@"key"] UTF8String], [row[@"cat"] UTF8String], [row[@"cls"] UTF8String]];
    return s;
}

static inline void SBMRespring(void) {
    pid_t pid = 0;
    const char *args[] = { "killall", "-9", "SpringBoard", NULL };
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
}

#endif /* SBM_COMMON_H */
