# 只出 arm64 单切片：XinaA15 环境对 arm64e 切片的 LC_DYLD_CHAINED_FIXUPS 处理有问题，
# 会导致 bundle 镜像在 libobjc readClass 阶段 SIGBUS（设置页闪退）。
# arm64 切片使用经典重定位，兼容性最好。
export ARCHS = arm64
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = StatusBarMoverPrefs

StatusBarMoverPrefs_FILES = SBMRootListController.m SBMItemsController.m SBMPreviewView.m
StatusBarMoverPrefs_INSTALL_PATH = /Library/PreferenceBundles
StatusBarMoverPrefs_FRAMEWORKS = UIKit
StatusBarMoverPrefs_PRIVATE_FRAMEWORKS = Preferences
StatusBarMoverPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
StatusBarMoverPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/StatusBarMover.plist$(ECHO_END)
