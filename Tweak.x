#import <UIKit/UIKit.h>
#import <notify.h>

// ============================================================================
//  StatusBarMover 1.0.2  —  per-icon offset for the iOS status bar
//  Target: iOS 15.x, rootless (XinaA15 / xina2)
//
//  1.0.2 ROOT-CAUSE rework (Safe Mode persisted through 1.0.1 despite @try,
//  which means the crash was NOT an ObjC exception — it was a hard crash or a
//  watchdog hang). Two concrete causes are removed:
//
//   (A) LAYOUT FEEDBACK LOOP  ->  we no longer touch `frame` at all.
//       The offset is applied with a LAYER TRANSLATION (self.transform). A
//       transform is composited on top of layout and does NOT feed back into
//       the frame layout pass, so SpringBoard can't get stuck relaying-out and
//       trip the watchdog. %orig(frame) is always called UNMODIFIED.
//
//   (B) SIGSEGV FROM performSelector: ON PRIMITIVE-RETURNING METHODS  ->  we
//       read the item identifier with KVC (valueForKey:). KVC boxes primitives
//       into NSNumber (so a non-object return can't be dereferenced as a
//       pointer) and raises a CATCHABLE NSException for unknown keys. No more
//       raw performSelector: on private accessors.
//
//   Plus: a kill-switch file lets you neuter the tweak WITHOUT uninstalling
//   (useful to escape a crash loop):
//       /var/mobile/Library/Preferences/com.minis.statusbarmover.disable
// ============================================================================

@interface _UIStatusBarItemView : UIView
@end

static NSString *const kAppID     = @"com.minis.statusbarmover";
static NSString *const kReload    = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile =
    @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";
static NSString *const kKillFile  =
    @"/var/mobile/Library/Preferences/com.minis.statusbarmover.disable";

static BOOL             gKill    = NO;     // hard bail-out (kill file present)
static BOOL             gEnabled = YES;
static BOOL             gLoaded  = NO;     // prefs loaded yet? (deferred)
static NSDictionary    *gOffsets = nil;    // key -> @{ @"x":num, @"y":num }
static NSMutableSet    *gSeen    = nil;    // identifiers (main thread only)
static BOOL             gWritePending = NO;

// ---- preferences -----------------------------------------------------------

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
        gLoaded = YES;
    } @catch (__unused NSException *e) {
        gOffsets = @{};
    }
}

// Load prefs lazily, the FIRST time a status bar item lays out — i.e. well
// after SpringBoard has finished process init. Calling CFPreferences from a
// dylib %ctor (during dyld initializer execution) is what crashed SpringBoard
// (SIGBUS in CFPreferencesAppSynchronize): the preferences subsystem is not
// safe to touch that early. Deferring it fixes the boot crash loop.
static void SBMEnsureLoaded(void) {
    if (gLoaded) return;
    LoadPrefs();
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
    return NSStringFromClass(v.class);   // always safe fallback
}

// Apply the stored offset as a TRANSLATION TRANSFORM (never touches frame).
static void SBMApplyTransform(UIView *v) {
    @try {
        SBMEnsureLoaded();        // lazy: safe to read prefs now (post-boot)
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

// ---- hook: apply offset WITHOUT modifying frame -----------------------------

%hook _UIStatusBarItemView

- (void)setFrame:(CGRect)frame {
    %orig(frame);                 // unmodified -> zero layout feedback
    if (gKill) return;
    SBMApplyTransform(self);
}

- (void)layoutSubviews {
    %orig;
    if (gKill) return;
    SBMApplyTransform(self);      // reassert if the container reset the transform
}

- (void)didMoveToSuperview {
    %orig;
    if (gKill) return;
    @try {                        // one level only; keep surface tiny
        if (self.superview) self.superview.clipsToBounds = NO;
    } @catch (__unused NSException *e) {}
}

%end

// ---- init -------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        // Kill-switch: create the .disable file to neuter the tweak without
        // uninstalling (lets you escape a crash loop from a terminal).
        gKill = [[NSFileManager defaultManager] fileExistsAtPath:kKillFile];
        gSeen = [NSMutableSet set];
        gOffsets = @{};
        if (gKill) return;        // do nothing else; hooks become no-ops

        // DO NOT touch CFPreferences here. This %ctor runs inside dyld's
        // initializer pass while SpringBoard is still bootstrapping, and
        // CFPreferencesAppSynchronize crashes (SIGBUS) that early. Prefs are
        // loaded lazily on the first status-bar layout (SBMEnsureLoaded), and
        // the reload observer is registered once the main run loop is up.
        dispatch_async(dispatch_get_main_queue(), ^{
            SBMEnsureLoaded();
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), NULL, ReloadNotify,
                (__bridge CFStringRef)kReload, NULL,
                CFNotificationSuspensionBehaviorCoalesce);
        });
    }
}
