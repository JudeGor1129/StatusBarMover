# CarPlayWalls

为 **CarPlay 的浅色 / 深色（日夜）模式分别指定自定义壁纸** 的越狱插件。
iOS 15.x · rootless（XinaA15 / xina2，安装到 `/var/jb`）。

---

## 一、原理（为什么这么做）

CarPlay 桌面壳进程是 **`com.apple.CarPlayApp`**，它画壁纸时走的是
`CarPlayUIServices.framework` 里的私有类：

```
CRSUIWallpaperPreferences.defaultWallpaper   →  CRSUIWallpaper 实例
[CRSUIWallpaper wallpaperImageCompatibleWithTraitCollection:tc]  →  UIImage
```

`tc.userInterfaceStyle` 就是车机当前的外观（浅色 / 深色），
所以 `-wallpaperImageCompatibleWithTraitCollection:` **就是**「浅色/深色分别换壁纸」
的唯一正确 Hook 点。

本插件只把该方法的**返回值**换成你的图片：

* 不碰 frame / 布局 / 视图层级 → **零 watchdog 风险**
* 任何异常都被 `@try` 吞掉，最坏情况 = 退回系统原图
* 附带 `-supportsDynamicAppearance` 返回 YES，确保系统会按日夜重新取图

（该接口在 iOS 14 / 15 / 16 / 17 的头文件中完全一致，iOS 18 起部分职责挪到
`CRSUISystemWallpaper`。）

## 二、注入范围

| 进程 | 用途 |
| --- | --- |
| `com.apple.CarPlayApp` | CarPlay 桌面壳（真正画壁纸的进程） |
| `com.apple.springboard` | 兜底（CarPlay 显示在手机屏幕的场景） |
| `com.apple.CarPlayWallpaper` | 壁纸选择器（若存在，缩略图也一并替换） |
| `com.apple.Preferences` | 设置界面（单独一个 dylib，见下） |

**设置界面为什么是单独一个 dylib**：PreferenceLoader 2.x 源码写死了
`if(!entry) continue;`，没有 `entry` 键的纯 plist 页面不会被注册；而带 `entry`
的代码 bundle 需要 Preferences 去 `dlopen` 我们的二进制，在这台设备上会在
dyld 映射镜像、libobjc `readClass` 阶段 SIGBUS。改走「注入器注入」这条已验证可用的
路径，可以完全绕开 dlopen。

## 三、安装

1. Actions 页面（`Build .deb`）下载 artifact 里的 `.deb`；
2. 用 Sileo / Zebra 安装；
3. **不要**在安装后立刻重启；先去看设置里有没有出现 **「CarPlay 壁纸」** 入口
   （`设置` 根列表底部）。

## 四、使用

### 1. 选图（推荐）
`设置 → CarPlay 壁纸 → 从相册选择浅色/深色壁纸`。
用 PHPicker，**不需要相册权限**，图片会被压到长边 ≤ 3840 存为
`/var/mobile/Library/CarPlayWalls/light.jpg` 与 `dark.jpg`。

### 2. 或者手动放图（Filza）
把图片放进 `/var/mobile/Library/CarPlayWalls/`，文件名以 `light` / `dark` 开头即可
（`light.png`、`dark.heic` 都能认）。配置页里也能直接填绝对路径。

### 3. 生效方式（全程在手机上，车机端不用点任何东西）
选图保存后，插件会**自动向车机进程下发一次刷新**：车机侧插件收到通知后清空图片缓存、
就地重刷壁纸视图，画面在 1~2 秒内换成新图。
若某次没有立刻变化，回设置页点 **「立即应用到车机（原地刷新）」**；
还不行就点 **「重启 CarPlay 画面」**（车机黑屏几秒后自动重载，属兜底手段）。
配置存在手机上，**重新插拔数据线后也一定生效**。

### 4. 建议
图片比例尽量与车机屏幕一致（如 `1920×720`、`800×480`），避免被拉伸。
只放一张浅色图时，勾选「深色图自动生成」会自动压暗 45% 作为夜间壁纸。

## 五、诊断与排错

* 打开 `诊断模式` → 在车里跑一会儿 → 回到设置页点 `查看诊断结果`。
* 诊断数据同时写在
  `/var/mobile/Library/Preferences/com.minis.carplaywalls.dump.plist`，
  内容包括：宿主进程、`CRSUIWallpaper` 是否存在、命中的方法次数、
  运行时所有含 `Wallpaper` 的类名。
* **紧急关停**：用 Filza 新建空文件
  `/var/mobile/Library/Preferences/com.minis.carplaywalls.disable`
  （插件每 2 秒检查一次，立即生效）。重新安装 deb 会自动清掉它。

## 六、工程结构

```
Makefile                    主 tweak（arm64 + arm64e，rootless）
CarPlayWalls.plist          注入过滤器
Tweak.x                     核心 Hook + 诊断
prefs/                      设置界面子工程（只注入 com.apple.Preferences）
  ├─ CPWInject.xm           往设置根列表塞入口
  ├─ CPWRootListController.m 设置页（含相册选图）
  └─ CarPlayWallsPrefs.plist 过滤器
layout/DEBIAN/postinst      建目录 / 写默认配置 / 绝不 killall SpringBoard
.github/workflows/build.yml GitHub Actions 出包
```

## 七、版本

* **1.0.0** — 首版：`CRSUIWallpaper` 取图替换 + 浅/深分离 + 相册选图 + 诊断。
* **1.1.0** — 交互对齐 Airaw：手机选图后**自动下发刷新、车机原地生效**（Darwin 通知 + 按图片指针精确重刷，
  不依赖视图类名）；新增「立即应用 / 重启 CarPlay 画面」按钮与「车机端最近取图」状态显示。
