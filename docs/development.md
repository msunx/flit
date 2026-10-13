# Flit · 开发与诊断

[返回 README](../README.md)

Flit 使用 Swift、AppKit 与 SwiftUI 实现，通过 ScreenCaptureKit 获取预览，通过 `SMAppService` 管理登录启动。项目没有第三方运行时或网络依赖。

## 构建与签名

需要 Apple Command Line Tools 与 Python 3。脚本直接调用 `swiftc`，生成当前主机架构的 `build/Flit.app`，最低系统部署目标为 macOS 14。

```sh
# 调试构建
zsh scripts/build.sh

# 优化构建
zsh scripts/build.sh release

# 启动应用
open build/Flit.app
```

`Package.swift` 供完整 Swift Package / Xcode 工具链使用。本机 CLT 的 PackageDescription 模块与动态库不匹配，因此当前验收使用构建脚本，未以 `swift build` 为入口。

本机工具链还存在两份相同的 SwiftBridging 模块定义。脚本仅在确认内容一致时生成项目内的 VFS overlay，忽略重复定义，不修改系统工具链文件。

产物使用本地临时签名（ad-hoc），尚未做 Developer ID 签名、公证、DMG 或通用架构分发。已验收环境为 Apple Silicon / macOS 27.0.1，部署目标不等同于所有 macOS 14+ 版本均已验证。

建议先确定应用的安装位置，再配置权限和登录启动。重新构建会改变临时签名，移动路径也可能使原授权失效；不必为了重复检查而重新编译。

## 权限排查

- 辅助功能用于读取窗口、接管全局快捷键、切换空间及可选的 Dock 固定。
- 屏幕录制仅用于预览，未开启时仍能使用名称与图标切换。Flit 不采集音频。
- macOS 27 中对应的设置名称可能是「设备控制和数据访问」与「录屏与系统录音」。
- 如果辅助功能已开，但快捷键未就绪，按应用提示检查「输入监控」，然后重新启动。

若系统开关显示已开启，而 Flit 仍显示未授权，退出 Flit，在系统设置中移除失效的旧条目，重新添加当前 `Flit.app` 并重启。系统身份验证需由用户本人完成，Flit 不会自行授予权限。

从终端直接运行二进制可能继承终端或开发工具的授权。需要验证应用自身权限时，通过 Launch Services 独立启动，并保存诊断输出：

```sh
open -n -W -a build/Flit.app --args --diagnose
```

## 诊断与界面渲染

以下两个入口只读诊断，不申请权限、不切换空间，也不记录窗口标题；Dock 诊断不会安装鼠标监听。

```sh
build/Flit.app/Contents/MacOS/Flit --diagnose
build/Flit.app/Contents/MacOS/Flit --diagnose-dock
```

渲染入口使用固定演示内容导出实际 SwiftUI 视图，不读取用户窗口，不启用全局快捷键监听。它也会使用临时文件检查名称保存、读回及错误恢复；不会改写用户配置。

```sh
build/Flit.app/Contents/MacOS/Flit --render-ui build/readme-preview/native
```

下面是手动集成验证入口，**会实际切到同屏另一类空间，再恢复原空间及前台应用**，请在适合切换桌面时运行。

```sh
build/Flit.app/Contents/MacOS/Flit --probe-spaces
```

## 实现与数据边界

### 空间与切换

枚举 Mission Control 顶部的桌面和全屏空间，每个空间一项。桌面中的普通、最小化窗口不单独列出，分屏和多个辅助窗口不会让同一空间重复出现。

有可激活窗口时，按目标窗口 ID 与辅助功能节点直接激活空间，不打开 Mission Control，不使用方向键逐个滑过中间空间。未被 AXWindows 列出的全屏窗口通过有时间上限的节点解析恢复，解析在后台执行并缓存。

没有可激活窗口的空桌面使用近零位移的完整 Dock 手势批次；macOS 27 使用适配的 IOHID 数据。系统内部仍按相邻空间处理事件，但不等待和播放逐项横向动画。实现只发送计算好的批次，随后核对目标空间，失败不盲目补发。空桌面导航要求指针位于目标屏幕，多显示器尚未完整验收。

空间枚举、窗口焦点与手势协议包含非公开系统接口，系统升级可能影响兼容性。无需修改系统快捷键、关闭 SIP 或注入系统进程。

### 最近使用排序

从 0.1.6 起，通过 Flit 成功切换的目标按空间身份移到首位，其他项目保持相对顺序。预览与列表共用排序；选择过程中不重排，取消或失败不更新最近使用。

排序按空间 UUID 维护，后台扫描及代表窗口变化不会覆盖已记录的顺序。重新打开面板、鼠标跨屏不会触发重排；此功能不承诺追踪所有从 Flit 外部发起的切换。

排序仅保留在当前进程会话。重启后回到系统空间顺序，首次打开时将当前空间置顶；快捷键默认选择第二项，Shift 反向选择末项。

### 别名与设置

设置文件为 `~/Library/Application Support/Flit/settings.json`，使用原子写入；损坏文件不会被自动覆盖。

空间别名使用空间 UUID。窗口别名机制绑定进程启动时间与窗口 ID，同一应用运行期间可恢复；应用重启后不猜测绑定，避免同名窗口误匹配。别名仅改变 Flit 内的显示，不修改其他应用。

### 预览

ScreenCaptureKit 按需获取窗口画面，图像只在内存缓存，不写入磁盘、不上传。桌面空间展示最近一次实际访问时的截图，尚未访问的空间使用占位。受保护内容和部分未激活全屏窗口可能无法捕获，保留图标；标题与切换不依赖预览完成。

### Dock 固定

默认关闭，首次开启优先选择当前 Dock 所在屏幕，无法识别时选择主屏幕。目标以显示器 UUID 保存；切换目标后，需要在所选屏幕底部唤出一次 Dock。

实现限制非目标屏幕底部的唤出动作，保留最底部 3 个逻辑像素，屏幕之间的上下接缝仍可通过。它只使用已有辅助功能权限，不改变鼠标位置、显示器排列或「显示器具有单独的空间」，不重启 Dock。

适用于底部 Dock、多屏独立空间。只连接一个屏幕、目标断开、Dock 位于侧边或权限不足时暂停；目标接回后恢复。关闭开关、暂停或退出 Flit 会立即解除限制。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| [Sources/Flit](../Sources/Flit) | 应用状态、空间切换、Dock 固定与原生界面 |
| [Resources](../Resources) | 应用图标、元数据与第三方声明 |
| [scripts/build.sh](../scripts/build.sh) | 本机应用构建与临时签名 |
| [NativePreview.swift](../Sources/Flit/NativePreview.swift) | 固定演示数据与原生界面渲染入口 |
| [README 素材说明](../assets/readme/README.md) | SVG 与演示界面图的来源和复现方式 |

`build/` 中的应用、缓存、日志与预览产物，以及 `design/` 和 `DESIGN.md` 中的本地设计探索、验收档案，不纳入 Git。可通过本页的构建、诊断与渲染命令生成对应产物。

## 第三方声明

空桌面手势协议改编自 InstantSpaceSwitcher。相应 MIT 许可及版权声明见 [ThirdPartyNotices.txt](../Resources/ThirdPartyNotices.txt)，构建脚本会将此文件复制到应用包中；该声明不代表为整个 Flit 项目另行指定许可证。
