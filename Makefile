export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
# XinaA15 (xina2) 是无根(rootless)越狱 → 必须以 rootless 方式打包，
# 安装路径会自动落到 /var/jb/... 之下。
# 如果你的环境其实是有根越狱，把下面这行注释掉即可。
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
