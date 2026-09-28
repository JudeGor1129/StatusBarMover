#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

// _UIStatusBarItemView is private. Declaring it as a UIView subclass gives the
// compiler correct typing (so `self.superview` and passing `self` where a
// UIView* is expected are both valid), instead of the forward declaration that
// %hook alone produces.
@interface _UIStatusBarItemView : UIView
- (id)item;
@end

// ============================================================================
//  StatusBarMover  —  per-icon X/Y offset for the iOS status bar
//  Target: iOS 15.x, rootless (XinaA15 / xina2)
//
//  Strategy: every status bar icon is an internal `_UIStatusBarItemView`.
//  We derive a STABLE KEY for each item (its display identifier, e.g.
//  "timeString", "batteryDetail", "cellularBars", "wifi", "bluetooth" ...),
//  look up a stored {dx, dy} offset for that key, and add it to the frame
//  UIKit assigns during layout. Because UIKit re-assigns the *base* frame on
//  every layout pass, adding the offset each time is correct and never drifts.
// ============================================================================

static NSString *const kAppID   = @"com.minis.statusbarmover";
static NSString *const kReload  = @"com.minis.statusbarmover/reload";
// Discovered item identifiers are dumped here so the Settings pane can list
// exactly what your device is currently showing.
static NSString *const kItemsFile =
    @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";

static BOOL             gEnabled = YES;
static NSDictionary    *gOffsets = nil;   // key -> @{ @"x": num, @"y": num }
static NSMutableSet    *gSeen    = nil;   // identifiers observed this session

// ---- preferences -----------------------------------------------------------

static void LoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);

    NSNumber *en = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(
        CFSTR("enabled"), (__bridge CFStringRef)kAppID);
    gEnabled = (en == nil) ? YES : en.boolValue;

    // All prefs are flat keys written by the Settings pane:
    //   "<identifier>.x"  and  "<identifier>.y"  (float, in points)
    NSDictionary *all = (__bridge_transfer NSDictionary *)
        CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)kAppID,
                                  kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost);

    NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
    for (NSString *k in all) {
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
    // Force a relayout of every status bar on screen (scene-based; the old
    // UIApplication.windows API is deprecated and errors under -Werror).
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                SBMRelayoutIn(w);
            }
        }
    });
}

// ---- helpers ---------------------------------------------------------------

// Derive the stable key for one item view.
static NSString *SBMKeyForItemView(UIView *itemView) {
    @try {
        if ([itemView respondsToSelector:@selector(item)]) {
            id item = [itemView performSelector:@selector(item)];
            if (item && [item respondsToSelector:@selector(displayItem)]) {
                id di = [item performSelector:@selector(displayItem)];
                if (di && [di respondsToSelector:@selector(identifier)]) {
                    NSString *ident = [di performSelector:@selector(identifier)];
                    if (ident.length) return ident;
                }
            }
            if (item && [item respondsToSelector:@selector(indicatorName)]) {
                NSString *n = [item performSelector:@selector(indicatorName)];
                if (n.length) return n;
            }
        }
    } @catch (__unused NSException *e) {}
    // Fallback: class name (e.g. "_UIStatusBarDataBatteryView").
    return NSStringFromClass(itemView.class);
}

static void SBMRecord(NSString *key) {
    if (!key.length) return;
    if (!gSeen) gSeen = [NSMutableSet set];
    if ([gSeen containsObject:key]) return;
    [gSeen addObject:key];
    // Persist the sorted list so Settings can enumerate real, live items.
    NSArray *sorted = [gSeen.allObjects
        sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    [sorted writeToFile:kItemsFile atomically:YES];
}

// ---- the actual hook -------------------------------------------------------

%hook _UIStatusBarItemView

- (void)setFrame:(CGRect)frame {
    NSString *key = SBMKeyForItemView(self);
    SBMRecord(key);

    if (gEnabled && key.length) {
        NSDictionary *off = gOffsets[key];
        if (off) {
            frame.origin.x += [off[@"x"] doubleValue];
            frame.origin.y += [off[@"y"] doubleValue];
        }
    }
    %orig(frame);
}

// Let icons move outside the tight status bar bounds without being clipped.
- (void)didMoveToSuperview {
    %orig;
    UIView *v = self.superview;
    int guard = 0;
    while (v && guard++ < 4) {
        v.clipsToBounds = NO;
        v = v.superview;
    }
}

%end

// ---- init ------------------------------------------------------------------

%ctor {
    gSeen = [NSMutableSet set];
    LoadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL, ReloadNotify,
        (__bridge CFStringRef)kReload, NULL,
        CFNotificationSuspensionBehaviorCoalesce);
}
