# README 素材

| 文件 | 来源与用途 |
| --- | --- |
| `hero.svg` | 自包含纯 SVG 标题，复用 `Resources/Flit.svg` 的双窗路径及应用鸢尾配色；无远程字体、脚本或栅格依赖。 |
| `overview.webp` | Flit 0.1.6 原生总览视图，展示两个桌面与六个全屏空间。 |
| `list.webp` | 同一组演示数据的列表视图。 |
| `dock.webp` | 原生「Dock 固定」设置视图，演示选中目标显示器。 |

界面图均来自 `Sources/Flit/NativePreview.swift`：实际 SwiftUI 视图搭配固定演示名称、图标与缩略图，不含用户窗口截图。三张 WebP 保留原尺寸和透明度，使用无损编码，转换后与源 PNG 的 RGBA 像素逐一比较一致。

## 重新生成

使用已构建的应用导出界面，无需为了文档重新编译或重新签名：

```sh
build/Flit.app/Contents/MacOS/Flit --render-ui build/readme-preview/native
```

将 `overview.png`、`list.png`、`settings-dock-on.png` 分别无损转换为这里的 `overview.webp`、`list.webp`、`dock.webp`。转换时不要裁剪、叠加文字或修改 UI 内容；更新 README 中的截图版本说明。

标题沿用应用的鸢尾配色：背景 `#F3EEF8`、文字 `#332C3E`、主色 `#7951D2`、浅紫 `#BEA5F0`。使用系统字体与 1200 × 300 的 SVG 画布，双窗标志配合 ⌘Tab 键帽表达切换操作。
