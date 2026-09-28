#import <UIKit/UIKit.h>
#import <notify.h>
#import <unistd.h>

// ============================================================================
//  StatusBarMover 1.0.4  —  per-icon offset for the iOS status bar
//  Target: iOS 15.x, rootless (XinaA15 / xina2)
//
//  WHY 1.0.0–1.0.3 all Safe-Mode'd (diagnosed from two SpringBoard .ips logs):
//    Both crashes were EXC_BAD_ACCESS / SIGBUS happening INSIDE MY %ctor while
//    dyld was still running image initializers (dyld4::...findAndRunAll-
//    Initializers -> jbinjector -> my constructor):
//      * v1.0.2: CFPreferencesAppSynchronize -> CFStringGetCharacterAtIndex 💥
//      * v1.0.3: NSFileManager fileExistsAtPath: -> getFileSystemRepresentation 💥
//    Common cause: messaging Foundation/CoreFoundation — which reads the
//    characters of my `@"..."` constant strings — during the dyld-init phase,
//    before the injected dylib's Objective-C constant-string class reference is
//    bound. That is a SIGBUS (a hardware signal), which is why the @try blocks
//    in 1.0.1/1.0.2 never caught it.
//
//  THE FIX (1.0.4):
//    * NO Foundation / CoreFoundation work at load time. The %ctor does ONLY
//      `%init;` (Logos hook registration — the same MSHookMessageEx every tweak
//      safely runs at load).
//    * ALL initialization (kill-switch check, prefs, reload observer) is
//      deferred via dispatch_once to the FIRST status-bar layout, which happens
//      long after SpringBoard has finished booting and the runtime is fully up.
//    * The kill-switch is checked with POSIX access() on a plain C string, so
//      even the safety mechanism has zero ObjC-constant-string dependency.
//    * Offsets are still applied as a non-destructive transform (never frame),
//      so there is no layout-feedback watchdog risk.
//
//  KILL-SWITCH (escape a crash loop without uninstalling):
//    touch /var/mobile/Library/Preferences/com.minis.statusbarmover.disable
//    …then respring. Delete the file to re-enable.
// ============================================================================

@interface _UIStatusBarItemView : UIView
@end

static NSString *const kAppID  = @"com.minis.statusbarmover";
static NSString *const kReload = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile =
    @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";
// C string on purpose — no NSString messaging needed for the safety check.
static const char *kKillPathC =
    "/var/mobile/Library/Preferences/com.minis.statusbarmover.disable";

static BOOL              gKill    = NO;
static BOOL              gEnabled = YES;
static NSDictionary     *gOffsets = nil;
static NSMutableSet     *gSeen    = nil;
static BOOL              gWritePending = NO;
static dispatch_once_t   gInitOnce;

// ---- preferences (only ever called post-boot) ------------------------------

static void LoadPrefs(void) {
    @try {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);

        NSNumber *en = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
            CFSTR("enabled"), (__bridge CFStringRef)kAppID);
        gEnabled = (en == nil) ? YES : en.boolValue;

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

// ---- deferred, one-time initialization (runs at first layout, post-boot) ----

static void SBMEnsureLoaded(void) {
    dispatch_once(&gInitOnce, ^{
        gSeen = [NSMutableSet set];
        gOffsets = @{};
        // POSIX kill-switch check — no ObjC, safe anywhere.
        if (access(kKillPathC, F_OK) == 0) { gKill = YES; return; }
        LoadPrefs();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, ReloadNotify,
            (__bridge CFStringRef)kReload, NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    });
}

// ---- SAFE key derivation via KVC (no raw performSelector:) ------------------

static NSString *SBMKeyForItemView(UIView *v) {
    @try {
        id item = [v valueForKey:@"item"];
        if (item) {
            @try {
                id di = [item valueForKey:@"displayItem"];
                id ident = di ? [di valueForKey:@"identifier"] : nil;
                if ([ident isKindOfClass:NSString.class] && [ident length])
                    return ident;
            } @catch (__unused NSException *e) {}
            @try {
                id nm = [item valueForKey:@"indicatorName"];
                if ([nm isKindOfClass:NSString.class] && [nm length])
                    return nm;
            } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}
    return NSStringFromClass(v.class);   // always-safe fallback
}

// Apply the stored offset as a TRANSLATION TRANSFORM (never touches frame).
static void SBMApplyTransform(UIView *v) {
    @try {
        CGAffineTransform t = CGAffineTransformIdentity;
        if (gEnabled) {
            NSString *key = SBMKeyForItemView(v);
            if (key.length) {
                if (![gSeen containsObject:key]) {
                    [gSeen addObject:key];
                    SBMScheduleWrite();
                }
                NSDictionary *off = gOffsets[key];
                if (off) {
                    CGFloat dx = [off[@"x"] doubleValue];
                    CGFloat dy = [off[@"y"] doubleValue];
                    if (dx != 0.0 || dy != 0.0)
                        t = CGAffineTransformMakeTranslation(dx, dy);
                }
            }
        }
        if (!CGAffineTransformEqualToTransform(v.transform, t))
            v.transform = t;
    } @catch (__unused NSException *e) {}
}

// ---- hooks (offset applied via transform, %orig always called) -------------

%hook _UIStatusBarItemView

- (void)setFrame:(CGRect)frame {
    %orig(frame);            // unmodified -> zero layout feedback
    SBMEnsureLoaded();       // one-time init on first real layout (post-boot)
    if (gKill) return;
    SBMApplyTransform(self);
}

- (void)layoutSubviews {
    %orig;
    SBMEnsureLoaded();
    if (gKill) return;
    SBMApplyTransform(self);
}

- (void)didMoveToSuperview {
    %orig;
    SBMEnsureLoaded();
    if (gKill) return;
    @try { if (self.superview) self.superview.clipsToBounds = NO; }
    @catch (__unused NSException *e) {}
}

%end

// ---- init: register hooks ONLY. No Foundation here (see header comment). ----

%ctor {
    %init;
}
