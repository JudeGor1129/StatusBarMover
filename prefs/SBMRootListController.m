#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>

// Settings pane for StatusBarMover.
// It auto-discovers the status bar items that the tweak has observed on THIS
// device (written to ...items.plist) and builds an X + Y offset stepper for
// each, so the list always matches what you actually have in your status bar.

static NSString *const kAppID   = @"com.minis.statusbarmover";
static NSString *const kReload  = @"com.minis.statusbarmover/reload";
static NSString *const kItemsFile =
    @"/var/mobile/Library/Preferences/com.minis.statusbarmover.items.plist";

// Pretty names for the common built-in identifiers.
static NSString *SBMPretty(NSString *ident) {
    static NSDictionary *map = nil;
    if (!map) map = @{
        @"timeString"      : @"Clock",
        @"batteryDetail"   : @"Battery %",
        @"battery"         : @"Battery",
        @"cellularBars"    : @"Cellular Signal",
        @"wifi"            : @"Wi‑Fi",
        @"bluetooth"       : @"Bluetooth",
        @"activity"        : @"Activity Spinner",
        @"location"        : @"Location Arrow",
        @"airplane"        : @"Airplane Mode",
        @"alarm"           : @"Alarm",
        @"vpn"             : @"VPN",
        @"orientationLock" : @"Rotation Lock",
        @"doNotDisturb"    : @"Focus / DND",
        @"rawSignal"       : @"Carrier Text",
        @"dataNetwork"     : @"Data Network",
    };
    NSString *p = map[ident];
    return p ?: ident;
}

@interface SBMRootListController : PSListController @end

@implementation SBMRootListController

- (NSArray *)itemIdentifiers {
    NSArray *items = [NSArray arrayWithContentsOfFile:kItemsFile];
    return items ?: @[];
}

- (NSMutableArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *s = [NSMutableArray new];

    // --- master switch group ---
    PSSpecifier *g0 = [PSSpecifier emptyGroupSpecifier];
    [g0 setProperty:@"Move each status bar icon by an X / Y offset (points). "
                     "Positive X = right, positive Y = down. Respring or toggle "
                     "an icon to refresh the discovered list."
             forKey:@"footerText"];
    [s addObject:g0];

    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"Enabled"
        target:self set:@selector(setPreferenceValue:specifier:)
        get:@selector(readPreferenceValue:) detail:Nil
        cell:PSSwitchCell edit:Nil];
    [sw setProperty:kAppID forKey:@"defaults"];
    [sw setProperty:@"enabled" forKey:@"key"];
    [sw setProperty:@YES forKey:@"default"];
    [s addObject:sw];

    // --- one X + one Y stepper per discovered item ---
    NSArray *idents = [self itemIdentifiers];
    if (idents.count == 0) {
        PSSpecifier *g = [PSSpecifier emptyGroupSpecifier];
        [g setProperty:@"No icons discovered yet. Open Control Center / respring "
                        "so the tweak can enumerate your status bar, then come back."
                 forKey:@"footerText"];
        [s addObject:g];
    }

    for (NSString *ident in idents) {
        PSSpecifier *grp = [PSSpecifier emptyGroupSpecifier];
        [grp setProperty:SBMPretty(ident) forKey:@"label"];
        [s addObject:grp];

        for (NSString *axis in @[ @"x", @"y" ]) {
            PSSpecifier *st = [PSSpecifier preferenceSpecifierNamed:
                    ([axis isEqualToString:@"x"] ? @"X offset" : @"Y offset")
                target:self set:@selector(setPreferenceValue:specifier:)
                get:@selector(readPreferenceValue:) detail:Nil
                cell:PSStepperCell edit:Nil];
            [st setProperty:kAppID forKey:@"defaults"];
            [st setProperty:[NSString stringWithFormat:@"%@.%@", ident, axis]
                     forKey:@"key"];
            [st setProperty:@0        forKey:@"default"];
            [st setProperty:@(-200)   forKey:@"min"];
            [st setProperty:@(200)    forKey:@"max"];
            [st setProperty:@1        forKey:@"increment"];
            [st setProperty:@YES      forKey:@"showValue"];
            [s addObject:st];
        }
    }

    // --- reset button ---
    PSSpecifier *gr = [PSSpecifier emptyGroupSpecifier];
    [s addObject:gr];
    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"Reset all offsets"
        target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
    [reset setProperty:@YES forKey:@"enabled"];
    [reset setButtonAction:@selector(resetAll)];
    [s addObject:reset];

    _specifiers = s;
    return _specifiers;
}

// Persist and broadcast on every change.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kAppID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);
    notify_post([kReload UTF8String]);
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)kAppID);
    return v ?: [specifier propertyForKey:@"default"];
}

- (void)resetAll {
    for (NSString *ident in [self itemIdentifiers]) {
        for (NSString *axis in @[ @"x", @"y" ]) {
            NSString *key = [NSString stringWithFormat:@"%@.%@", ident, axis];
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                     (__bridge CFStringRef)kAppID);
        }
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kAppID);
    notify_post([kReload UTF8String]);
    // rebuild UI
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
