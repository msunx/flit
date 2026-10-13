#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
CONFIG="${1:-debug}"
if [[ "$CONFIG" != debug && "$CONFIG" != release ]]; then
    print -u2 'Usage: scripts/build.sh [debug|release]'
    exit 1
fi
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache"
APP="${FLIT_BUILD_APP:-$ROOT/build/Flit.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
FLAGS=(-Onone -g)
if [[ "$CONFIG" == release ]]; then FLAGS=(-O -file-prefix-map "$ROOT=Flit"); fi
FLIT_BUILD_SDK="${FLIT_BUILD_SDK:-$(xcrun --show-sdk-path)}"
OVERLAY="$(python3 "$ROOT/scripts/toolchain-overlay.py")"
if [[ -n "$OVERLAY" ]]; then FLAGS+=(-vfsoverlay "$OVERLAY" -Xcc -ivfsoverlay -Xcc "$OVERLAY"); fi
swiftc -explicit-module-build -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -sdk "$FLIT_BUILD_SDK" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" "${FLAGS[@]}" -module-name Flit \
    "$ROOT"/Sources/Flit/*.swift -framework AppKit -framework ScreenCaptureKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/Flit"
if [[ "$CONFIG" == release ]]; then strip -S -x "$APP/Contents/MacOS/Flit"; fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ThirdPartyNotices.txt" "$APP/Contents/Resources/ThirdPartyNotices.txt"
if [[ -f "$ROOT/Resources/Flit.icns" ]]; then
    cp "$ROOT/Resources/Flit.icns" "$APP/Contents/Resources/Flit.icns"
fi
codesign --force --sign - --identifier com.muyang.flit "$APP"
print "Built: $APP"
