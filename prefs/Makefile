# 这个 dylib 只注入「设置」App（com.apple.Preferences），
# 提供设置界面。它链接 Preferences.framework，因此绝不能进 SpringBoard。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StatusBarMoverPrefs

StatusBarMoverPrefs_FILES = SBMInject.xm SBMRootListController.m SBMItemsController.m SBMPreviewView.m
StatusBarMoverPrefs_FRAMEWORKS = UIKit
StatusBarMoverPrefs_PRIVATE_FRAMEWORKS = Preferences
StatusBarMoverPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
