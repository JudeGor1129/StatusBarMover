# 系统 app 进程（Preferences）只接受 arm64e 切片 → 必须双切片。
export ARCHS = arm64 arm64e
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
StatusBarMoverPrefs_INFO_PLIST = Info.plist

include $(THEOS_MAKE_PATH)/bundle.mk

# 两条并行的设置入口，便于确定哪种机制在这台设备上可用：
#   1) StatusBarMover.plist      → 代码 bundle（图形化拖动预览）
#   2) StatusBarMoverList.plist  → 纯资源 bundle（只有 Info.plist + Root.plist，无任何二进制）
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp StatusBarMover.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/StatusBarMover.plist$(ECHO_END)
	$(ECHO_NOTHING)cp StatusBarMoverList.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/StatusBarMoverList.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/StatusBarMoverListPrefs.bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp ListPrefs-Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/StatusBarMoverListPrefs.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/StatusBarMoverListPrefs.bundle/Root.plist"$(ECHO_END)
