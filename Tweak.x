#import <UIKit/UIKit.h>
#import <notify.h>

// ============================================================================
//  StatusBarMover 1.0.1  —  per-icon X/Y offset for the iOS status bar
//  Target: iOS 15.x, rootless (XinaA15 / xina2)
//
//  1.0.1 safety rework (fixes Safe Mode / SpringBoard crash-loop):
//   * Injects into SpringBoard ONLY (see StatusBarMover.plist) instead of all
//     of UIKit — a frame-mutating hook has no business in every app + daemon.
//   * setFrame: is wrapped so NO exception can ever escape our code; %orig is
//     ALWAYS called, so even a bug in our logic can't break status-bar layout.
//   * Identifier values are type-checked (isKindOfClass:NSString) before use.
//   * Item discovery no longer writes to disk on the layout hot path; the write
//     is snapshotted on the main thread and flushed on a throttled background
//     queue (no data race, no per-frame I/O).
// ============================================================================

// _UIStatusBarItemView is private. Declaring it as a UIView subclass gives the
// compiler correct typing for self.superview and for passing self as UIView*.
@interface _UIStatusBarItemView : UIView
- (id)item;
@end

static NSString *const kAppID     = @"com.minis.statusbarmover";
static NSString *const kReload    = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile =
    @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";

static BOOL             gEnabled = YES;
static NSDictionary    *gOffsets = nil;   // key -> @{ @"x": num, @"y": num }
static NSMutableSet    *gSeen    = nil;   // identifiers observed (main thread only)
static BOOL             gWritePending = NO;

// ---- preferences -----------------------------------------------------------

static void LoadPrefs(void) {
    @try {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);

        NSNumber *en = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
            CFSTR("enabled"), (__bridge CFStringRef)kAppID);
        gEnabled = (en == nil) ? YES : en.boolValue;

        // Flat keys written by the Settings pane: "<identifier>.x" / ".y".
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

// ---- throttled, race-free discovery persistence ----------------------------
// Snapshot is taken on the main thread (where gSeen is mutated); the actual
// disk write happens off-thread so status-bar layout is never blocked by I/O.
static void SBMScheduleWrite(void) {
    if (gWritePending) return;
    gWritePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gWritePending = NO;
        NSArray *snap = [[gSeen allObjects]
            sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try { [snap writeToFile:kItemsFile atomically:YES]; }
            @catch (__unused NSException *e) {}
        });
    });
}

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

// ---- helpers ---------------------------------------------------------------

// Derive a stable key for one item view. Never throws.
static NSString *SBMKeyForItemView(UIView *itemView) {
    @try {
        if ([itemView respondsToSelector:@selector(item)]) {
            id item = [itemView performSelector:@selector(item)];
            if (item && [item respondsToSelector:@selector(displayItem)]) {
                id di = [item performSelector:@selector(displayItem)];
                if (di && [di respondsToSelector:@selector(identifier)]) {
                    id ident = [di performSelector:@selector(identifier)];
                    if ([ident isKindOfClass:NSString.class] && [ident length])
                        return ident;
                }
            }
            if (item && [item respondsToSelector:@selector(indicatorName)]) {
                id nm = [item performSelector:@selector(indicatorName)];
                if ([nm isKindOfClass:NSString.class] && [nm length])
                    return nm;
            }
        }
    } @catch (__unused NSException *e) {}
    // Fallback: class name (e.g. "_UIStatusBarDataBatteryView").
    return NSStringFromClass(itemView.class);
}

// ---- the actual hook -------------------------------------------------------

%hook _UIStatusBarItemView

- (void)setFrame:(CGRect)frame {
    // Guarantee: whatever happens in here, %orig runs with a sane frame.
    @try {
        if (gEnabled) {
            NSString *key = SBMKeyForItemView(self);
            if (key.length) {
                if (![gSeen containsObject:key]) {
                    [gSeen addObject:key];
                    SBMScheduleWrite();
                }
                NSDictionary *off = gOffsets[key];
                if (off) {
                    frame.origin.x += [off[@"x"] doubleValue];
                    frame.origin.y += [off[@"y"] doubleValue];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    %orig(frame);
}

// Let icons move slightly outside the tight bar bounds without being clipped.
- (void)didMoveToSuperview {
    %orig;
    @try {
        UIView *v = self.superview;
        int guard = 0;
        while (v && guard++ < 3) {
            v.clipsToBounds = NO;
            v = v.superview;
        }
    } @catch (__unused NSException *e) {}
}

%end

// ---- init ------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        gSeen = [NSMutableSet set];
        gOffsets = @{};
        LoadPrefs();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, ReloadNotify,
            (__bridge CFStringRef)kReload, NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    }
}
