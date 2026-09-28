# StatusBarMover

A rootless jailbreak tweak that lets you move **each** status bar icon
independently by an X / Y offset (in points). Built for **iOS 15.x** on the
**XinaA15 (xina2)** rootless jailbreak.

It works by hooking the private status-bar *item view* and adding your stored
per-item offset to the frame UIKit assigns on every layout pass (so it never
drifts). The Settings pane **auto-discovers** the icons your device actually
shows and builds an X + Y stepper for each one.

---

## Why it isn't a prebuilt `.deb`

Compiling an iOS tweak needs the **Theos** build system **plus an iOS SDK and
the Darwin/arm64 clang toolchain**. That can't run inside the iSH/Alpine shell
this project was generated in (no SDK, no cross-compiler). You build it on a
Theos host, which takes ~10 seconds.

## Requirements to build

- A machine with **Theos** installed: https://theos.dev/docs/installation
  - macOS (with Xcode) **or** Linux/WSL with an iOS SDK dropped into
    `$THEOS/sdks/`.
- `ldid` and `dpkg-deb` (installed automatically by the Theos bootstrap).

## Build

```bash
cd StatusBarMover
make package FINALPACKAGE=1
# -> ./packages/com.minis.statusbarmover_1.0.0_iphoneos-arm64.deb  (rootless)
```

Install it straight to a connected, SSH-reachable device instead:

```bash
make do THEOS_DEVICE_IP=<phone-ip> THEOS_DEVICE_PORT=22
```

## Install on the phone

1. Copy the `.deb` to the device.
2. Open it in **Sileo** or **Zebra** (both ship with XinaA15) → Install.
3. It resprings automatically.
4. Go to **Settings → StatusBarMover**.

> First launch shows an empty list. Pull down Control Center or respring once so
> the tweak can enumerate your live status bar, then reopen the pane — every
> discovered icon (Clock, Battery %, Wi‑Fi, Cellular, Bluetooth, …) gets an
> **X offset** and **Y offset** stepper. Positive X = right, positive Y = down.
> Changes apply instantly (a Darwin notification triggers a status-bar
> relayout).

## Project layout

```
StatusBarMover/
├── Makefile                     # rootless tweak + prefs aggregate
├── control                      # rootless package metadata
├── StatusBarMover.plist         # inject into UIKit (see scope note)
├── Tweak.x                      # the hook: per-item frame offset + discovery
└── prefs/
    ├── Makefile
    ├── entry.plist              # PreferenceLoader entry
    └── SBMRootListController.m  # dynamic, self-discovering settings pane
```

## Injection scope (important)

`StatusBarMover.plist` filters on `com.apple.UIKit`, so the tweak loads into
**every** UIKit process. That's the broadest option and moves icons in the
status bar **everywhere** (home screen, lock screen, and inside apps that render
their own bar).

- To limit it to the home/lock screen only, change the filter to
  `com.apple.springboard` and respring. Lighter, but won't affect the bar shown
  inside third-party apps.

## Notes / troubleshooting

- **Offsets don't apply inside third-party apps?** Injected code shares the host
  app's sandbox. Reading the preference domain across containers relies on your
  jailbreak's sandbox relaxation (normal on XinaA15). If it misbehaves in a
  specific app, switch the filter to `com.apple.springboard`.
- **An icon isn't in the list?** It only appears after it has been shown at
  least once while the tweak was loaded. Toggle it on (e.g. enable Bluetooth) or
  respring.
- **Reset** button clears every stored offset.
- Identifiers fall back to the item view's class name if the system doesn't
  expose a friendly identifier — the pane still lets you nudge it.

## Uninstall

Remove **StatusBarMover** from Sileo/Zebra; it resprings and all offsets are
gone.
