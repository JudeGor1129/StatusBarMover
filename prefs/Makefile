export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = StatusBarMoverPrefs

StatusBarMoverPrefs_FILES = SBMRootListController.m
StatusBarMoverPrefs_INSTALL_PATH = /Library/PreferenceBundles
StatusBarMoverPrefs_FRAMEWORKS = UIKit
StatusBarMoverPrefs_PRIVATE_FRAMEWORKS = Preferences
StatusBarMoverPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/StatusBarMover.plist$(ECHO_END)
