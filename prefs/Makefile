# 设置界面 dylib：只注入「设置」App（com.apple.Preferences）
#
# ★ 为什么不走 PreferenceLoader 的 bundle / 纯 plist 页面：
#   · PreferenceLoader 2.x 的源码里明确写着 `NSDictionary *entry = [plPlist objectForKey:@"entry"];
#     if(!entry) continue;` —— 没有 entry 键的 plist 页面根本不会被注册。
#   · 带 entry 的代码 bundle 需要 Preferences 去 dlopen 我们的二进制，而在
#     XinaA15 / iOS 15.4.1 上这条路径会在 dyld 映射镜像、libobjc readClass 阶段 SIGBUS。
#   · 而「被越狱注入器注入」这条路径是正常工作的（StatusBarMover 已验证），
#     所以把设置界面直接编进一个只注入 com.apple.Preferences 的 dylib。
#
# ★ 这个 dylib 链接 Preferences.framework，绝不能进 SpringBoard —— 因此过滤器单独一份。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CarPlayWallsPrefs

CarPlayWallsPrefs_FILES = CPWInject.xm CPWRootListController.m
CarPlayWallsPrefs_FRAMEWORKS = UIKit PhotosUI
CarPlayWallsPrefs_PRIVATE_FRAMEWORKS = Preferences
CarPlayWallsPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
