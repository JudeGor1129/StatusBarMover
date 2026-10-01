# =============================================================================
#  CarPlayWalls —— 为 CarPlay 的浅色 / 深色模式分别设置自定义壁纸
#
#  环境：XinaA15 (xina2) 无根越狱 → THEOS_PACKAGE_SCHEME = rootless（装到 /var/jb）
#  目标进程：
#    · com.apple.CarPlayApp  —— CarPlay 桌面壳（真正画壁纸的进程）
#    · com.apple.springboard —— 兜底（CarPlay 投到手机屏幕的场景）
#    · com.apple.CarPlayWallpaper —— 壁纸选择器（若存在，缩略图也会换成自己的图）
#
#  切片说明：设 app 进程只接受 arm64e，但纯 arm64 也能被加载；
#  这里跟已验证可用的 StatusBarMover 保持一致，出 arm64 + arm64e 双切片。
# =============================================================================
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CarPlayWalls

CarPlayWalls_FILES = Tweak.x
CarPlayWalls_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CarPlayWalls_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

# 设置界面：单独一个只注入「设置」App 的 dylib（绕开 XinaA15 下 dlopen bundle 的 SIGBUS 问题）
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
