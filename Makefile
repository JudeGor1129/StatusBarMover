# 系统 app 进程（Preferences）只接受 arm64e 切片 → 必须双切片。
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
# XinaA15 (xina2) 是无根(rootless)越狱 → 必须以 rootless 方式打包，
# 安装路径会自动落到 /var/jb/... 之下。
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StatusBarMover

StatusBarMover_FILES = Tweak.x
StatusBarMover_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
StatusBarMover_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# 2.0.9 起临时只出「状态栏本体」：设置界面（prefs 子工程）先不打包，
# 避免它影响「设置」App。等核心功能确认生效后再单独恢复。
# SUBPROJECTS += prefs
# include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
