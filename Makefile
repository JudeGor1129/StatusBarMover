# XinaA15 环境必须使用 arm64e 切片（系统 app 进程只接受 arm64e）。
# 但 arm64e + LC_DYLD_CHAINED_FIXUPS 在该环境下会导致 libobjc readClass SIGBUS
# （链式重定位未被应用，未解码的指针被当地址解引用）。
# 解法：保留 arm64e，但强制退回经典重定位：
#   1) 部署目标设为 13.0（低于链接器默认启用 chained fixups 的 13.4 阈值）
#   2) 额外显式传 -no_fixup_chains 兜底
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:13.0
# XinaA15 (xina2) 是无根(rootless)越狱 → 必须以 rootless 方式打包，
# 安装路径会自动落到 /var/jb/... 之下。
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StatusBarMover

StatusBarMover_FILES = Tweak.x
StatusBarMover_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new
StatusBarMover_FRAMEWORKS = UIKit
StatusBarMover_LDFLAGS = -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
