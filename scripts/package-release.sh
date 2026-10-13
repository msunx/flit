#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
FLIT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
FLIT_ARCH="$(uname -m)"
if [[ "$FLIT_ARCH" != arm64 && "$FLIT_ARCH" != x86_64 ]]; then
    print -u2 "Unsupported build architecture: $FLIT_ARCH"
    exit 1
fi
FLIT_OUTPUT="${FLIT_RELEASE_DIR:-$ROOT/build/releases/$FLIT_VERSION-$FLIT_ARCH}"
if [[ -e "$FLIT_OUTPUT" ]]; then
    print -u2 "Output already exists: $FLIT_OUTPUT. Set FLIT_RELEASE_DIR to a new directory."
    exit 1
fi
mkdir -p "$FLIT_OUTPUT/work/dmg"
FLIT_OUTPUT="${FLIT_OUTPUT:A}"
FLIT_DMG_ROOT="$FLIT_OUTPUT/work/dmg"
FLIT_APP="$FLIT_DMG_ROOT/Flit.app"
FLIT_STEM="Flit-$FLIT_VERSION-macos-$FLIT_ARCH"

# Build a separate app so the running development copy keeps its existing signature.
FLIT_BUILD_APP="$FLIT_APP" zsh "$ROOT/scripts/build.sh" release
xattr -cr "$FLIT_APP"
codesign --verify --deep --strict "$FLIT_APP"
ln -s /Applications "$FLIT_DMG_ROOT/Applications"
cat > "$FLIT_DMG_ROOT/INSTALL.txt" <<EOF
Flit $FLIT_VERSION · macOS $FLIT_ARCH

安装
1. 如果已运行 Flit，先从菜单栏退出。
2. 将 Flit.app 拖到 Applications，再从“应用程序”打开。
3. 首次运行在 Flit 设置中开启辅助功能；屏幕录制为可选，用于窗口预览。

当前安装包使用本地临时签名，未经 Developer ID 签名或 Apple 公证。
若 macOS 阻止打开，请先确认下载来源，再按 Apple 的说明在系统设置中确认打开：
https://support.apple.com/102445

重新安装可能需要为新版本恢复辅助功能或屏幕录制授权。
系统部署目标为 macOS 14+；具体已验证环境和兼容限制见发布页。

发布页：https://github.com/msunx/flit/releases/tag/v$FLIT_VERSION
EOF
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$FLIT_APP" "$FLIT_OUTPUT/$FLIT_STEM.zip"
hdiutil create -volname "Flit $FLIT_VERSION" -srcfolder "$FLIT_DMG_ROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$FLIT_OUTPUT/$FLIT_STEM.dmg"
(
    cd "$FLIT_OUTPUT"
    shasum -a 256 "$FLIT_STEM.dmg" "$FLIT_STEM.zip" > SHA256SUMS.txt
)
print "Release files: $FLIT_OUTPUT"
