# StatusBarMover 2.0

自由调节 iOS 状态栏图标位置 —— **信号 / 数据网络 / Wi-Fi / 电池 / 电量百分比 / 时间**，每一项都能独立设置水平与垂直偏移。

> 适用环境：**iPhone 13 Pro Max · iOS 15.4.1 · XinaA15 (xina2) 无根越狱**
> 版本：2.0.0 · 包名 `com.minis.statusbarmover` · SpringBoard 注入

---

## 一、这一版有什么

| | |
|---|---|
| **可拖动的实时预览** | 设置页顶部就是一条模拟状态栏。**按住图标直接拖**，松手即生效 —— 拖的不是示意图，用的就是插件运行时那套偏移逻辑，屏幕上真实的状态栏会同步跟着动。双击图标 = 复位该项。 |
| **六个常用图标各一组滑块** | 信号 / 数据网络 / Wi-Fi / 电池 / 电量百分比 / 时间，每组都有「水平偏移 ±60pt」「垂直偏移 ±25pt」两条滑块，用于 ±1pt 的精细修正。 |
| **自动识别本机图标** | 插件在运行时实测发现你设备上真实存在的状态栏图标，写进 `items.plist`；设置页读取它自动生成条目，不需要你填任何标识符。 |
| **全部图标（高级）** | 蓝牙、定位、闹钟、运营商文字…… 各种边角图标都在这一页，一个都不会漏。 |
| **非破坏性偏移** | 偏移以 `CGAffineTransform` 平移实现，**绝不触碰 frame**，与系统布局引擎零反馈，不会触发 watchdog。 |
| **POSIX 紧急开关** | 万一装出问题，`touch` 一个文件 + 重启 SpringBoard 就能停用，不需要卸载。 |

---

## 二、目录结构

```
StatusBarMover/
├── Tweak.x                      # 插件本体：hook _UIStatusBarItemView 并施加 transform
├── Makefile                     # 主工程（rootless）
├── control                      # deb 元信息
├── StatusBarMover.plist         # 注入过滤：仅 SpringBoard
├── build.sh                     # 本地一键打包
├── .github/workflows/build.yml  # 推送到 GitHub 自动编译出 .deb
└── prefs/
    ├── Makefile
    ├── entry.plist              # 设置页入口（设置 → 状态栏图标位置）
    ├── SBMCommon.h              # 共用常量 / 偏好读写 / 图标分类 / 诊断
    ├── SBMRootListController.m  # 主设置页：实时预览 + 六组滑块
    ├── SBMPreviewView.h/.m      # 可拖动的状态栏预览视图
    └── SBMItemsController.m     # 「全部图标（高级）」页
```

---

## 三、编译

### 方式 A：GitHub Actions（推荐，不用装任何环境）

1. 把本仓库内容推到 GitHub 的 `main` 分支；
2. 打开仓库 **Actions → Build .deb → Run workflow**；
3. 跑完后在该次运行页面底部的 **Artifacts** 里下载 `StatusBarMover-deb`，解压得到 `.deb`。

### 方式 B：本地 Theos

```bash
export THEOS=/opt/theos
./build.sh
# 产物在 packages/*.deb
```

---

## 四、安装

1. 把 `.deb` 传到手机（AirDrop / 文件 App / 邮件都行）；
2. 用 **Sileo** 或 **Zebra** 打开并安装（无根环境会自动装到 `/var/jb/...`）；
3. 安装后会自动重启 SpringBoard；
4. 进入 **设置 → 状态栏图标位置** 开始调节。

也可以走 SSH：

```bash
make do THEOS_DEVICE_IP=<手机IP> THEOS_DEVICE_PORT=22
```

---

## 五、使用

- 打开设置页，顶部就是预览条。**按住信号 / Wi-Fi / 电池等图标左右上下拖动**，屏幕顶部真实的状态栏会同步变化。
- 想精确到 1pt，用下面每一组的**水平偏移 / 垂直偏移**滑块。
- 「当前数值」一行显示该项目前的 X / Y；「重置全部偏移」一键归零。
- 改完**不需要重启**，插件收到通知后会立刻重新布局。

### 紧急开关（装坏了进安全模式时用）

```bash
touch /var/mobile/Library/Preferences/com.minis.statusbarmover.disable
# 然后重启 SpringBoard；删除该文件即可恢复
```

---

## 六、实现原理与稳定性设计

**Hook 点**：状态栏里每个图标都是一个 `_UIStatusBarItemView` 实例。插件 hook 它的
`setFrame:` / `layoutSubviews` / `didMoveToSuperview`，在系统布局完成后叠加一个平移变换。

**为什么用 transform 而不是直接改 frame**：frame 由系统布局引擎掌管，直接改会在下一次布局被覆盖，
并且会和布局引擎互相反馈，极易触发 SpringBoard 看门狗崩溃。transform 属于渲染层叠加，
不参与约束解算，所以完全无副作用。

**为什么构造函数里一行 Foundation 代码都不能有**：1.0.0–1.0.3 全部在 `%ctor` 里崩溃
（EXC_BAD_ACCESS / SIGBUS）。原因是 dyld 还在执行 image initializer 的阶段
（jbinjector → 本 dylib 构造函数）就调用了 Foundation / CoreFoundation，
此时 ObjC 常量字符串的类引用尚未绑定 —— 这是硬件信号，`@try` 抓不住。因此：

- `%ctor` 里只有 `%init;`；
- 所有初始化（读偏好、注册通知）用 `dispatch_once` 延迟到**第一次状态栏布局**时执行；
- 紧急开关用 POSIX `access()` 检查纯 C 字符串路径，连常量 `NSString` 都不碰。

---

## 七、常见问题

**Q：设置页里某一组显示「未检测到」？**
说明系统当前没有创建那个图标视图（比如 Wi-Fi 关着的时候）。开着对应功能、回到本页即可；
也可以先在那一组里调，等图标出现后偏移会自动套用。

**Q：某一项拖了没反应？**
去「全部图标（高级）」页，点「复制诊断信息到剪贴板」，把清单发出来做精确适配。

**Q：和别的状态栏插件冲突？**
同类插件（NiceBarX 等）会接管同一批视图，建议只留一个。

---

## 八、偏好键约定

```
<identifier>.x   水平偏移（pt）
<identifier>.y   垂直偏移（pt）
```
`identifier` 是插件在设备上实测发现的字符串，例如
`wifi` / `battery` / `batteryDetail` / `cellularBars` / `dataNetwork` / `timeString`。
偏好文件：`/var/mobile/Library/Preferences/com.minis.statusbarmover.plist`
