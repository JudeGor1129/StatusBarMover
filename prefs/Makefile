# 系统 app 进程（Preferences）只接受 arm64e，所以必须双切片。
# arm64e 在 iOS 14+ 由链接器强制使用 chained fixups，无法关闭 —— 因此本工程
# 不依赖「prefs bundle 二进制」作为设置页入口（那正是之前闪退的原因），
# 主设置页改为纯 plist 页面，由 Preferences 自己渲染，不需要加载任何二进制。
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
StatusBarMoverPrefs_LDFLAGS = -Wl,-bundle -Wl,-undefined,dynamic_lookup
# 让 Theos 使用我们自己提供的 Info.plist（里面含 NSPrincipalClass）
StatusBarMoverPrefs_INFO_PLIST = Info.plist

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp StatusBarMoverPrefs.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/StatusBarMover.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle/Info.plist"$(ECHO_END)
