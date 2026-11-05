#!/usr/bin/env bash
set -euo pipefail

PINWHERE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINWHERE_APP="${1:-$PINWHERE_ROOT/dist/PinWhere.app}"
[ -d "$PINWHERE_APP" ] || { echo "请先构建应用，或传入已构建的 .app 路径。" >&2; exit 1; }
[ -x "$PINWHERE_APP/Contents/Resources/backend.sh" ] || { echo "应用缺少随包管理脚本，请使用最新构建脚本重新构建。" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$PINWHERE_APP"
PINWHERE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PINWHERE_APP/Contents/Info.plist")"
PINWHERE_ARCH="$(/usr/bin/lipo -archs "$PINWHERE_APP/Contents/MacOS/PinWhere" | tr ' ' '-')"
PINWHERE_OUTPUT="${2:-$PINWHERE_ROOT/dist/PinWhere-$PINWHERE_VERSION-$PINWHERE_ARCH.dmg}"
[ ! -e "$PINWHERE_OUTPUT" ] || { echo "输出文件已存在，请指定新路径；不会覆盖现有镜像。" >&2; exit 1; }
mkdir -p "$(dirname "$PINWHERE_OUTPUT")"
PINWHERE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pinwhere-dmg.XXXXXX")"
trap 'rm -rf "$PINWHERE_STAGE"' EXIT
/usr/bin/ditto "$PINWHERE_APP" "$PINWHERE_STAGE/PinWhere.app"
ln -s /Applications "$PINWHERE_STAGE/Applications"
cp "$PINWHERE_ROOT/Resources/安装前必读.txt" "$PINWHERE_STAGE/安装前必读.txt"
cp "$PINWHERE_ROOT/使用说明.txt" "$PINWHERE_STAGE/使用说明.txt"
cp "$PINWHERE_ROOT/THIRD_PARTY_NOTICES.txt" "$PINWHERE_STAGE/THIRD_PARTY_NOTICES.txt"
/usr/bin/hdiutil create -volname PinWhere -srcfolder "$PINWHERE_STAGE" -format UDZO "$PINWHERE_OUTPUT"
/usr/bin/hdiutil verify "$PINWHERE_OUTPUT"
(
  cd "$(dirname "$PINWHERE_OUTPUT")"
  /usr/bin/shasum -a 256 "$(basename "$PINWHERE_OUTPUT")" > "$(basename "$PINWHERE_OUTPUT").sha256"
)
echo "DMG 已生成：$PINWHERE_OUTPUT"
echo "DMG 只负责分发；首次使用仍需系统设置、扩展加载与用户授权。"
