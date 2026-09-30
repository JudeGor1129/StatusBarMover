# 与主工程一致：系统 app 进程只接受 arm64e，但必须避开 chained fixups
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:13.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = StatusBarMoverPrefs

StatusBarMoverPrefs_FILES = SBMRootListController.m SBMItemsController.m SBMPreviewView.m
StatusBarMoverPrefs_INSTALL_PATH = /Library/PreferenceBundles
StatusBarMoverPrefs_FRAMEWORKS = UIKit
StatusBarMoverPrefs_PRIVATE_FRAMEWORKS = Preferences
StatusBarMoverPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new
StatusBarMoverPrefs_LDFLAGS = -Wl,-no_fixup_chains -Wl,-undefined,dynamic_lookup
# 让 Theos 使用我们自己提供的 Info.plist（里面含 NSPrincipalClass，
# 这是 Preferences 加载 bundle 时必需的）
StatusBarMoverPrefs_INFO_PLIST = Info.plist

include $(THEOS_MAKE_PATH)/bundle.mk

# ★ 确认 Info.plist 一定被装进 .bundle 里。
#   之前打出来的包里 bundle 目录只有一个可执行文件，没有 Info.plist，
#   于是 Preferences 只会显示「未能载入软件包…已损坏或丢失必要的资源」。
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/StatusBarMover.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle"$(ECHO_END)
	$(ECHO_NOTHING)cp Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/$(BUNDLE_NAME).bundle/Info.plist"$(ECHO_END)
