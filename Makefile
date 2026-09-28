export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
# XinaA15 (xina2) is a ROOTLESS jailbreak -> package must be rootless.
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StatusBarMover

StatusBarMover_FILES = Tweak.x
StatusBarMover_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
StatusBarMover_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
