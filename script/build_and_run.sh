#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PinWhere"
APP_BUNDLE="${PINWHERE_OUTPUT_DIR:-$ROOT_DIR/dist}/$APP_NAME.app"
APP_BUNDLE="$(/usr/bin/python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$APP_BUNDLE")"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
cd "$ROOT_DIR"

case "$MODE" in
  run|--verify|verify|--debug|debug|--logs|logs|--telemetry|telemetry|--build-only) ;;
  *) echo "用法：$0 [--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac

if [ "$MODE" = "--build-only" ] && [ "$APP_BUNDLE" != "$ROOT_DIR/dist/$APP_NAME.app" ]; then
  # 独立目录只生成分发副本，不停止、覆盖当前正在使用的应用和后台。
  for PINWHERE_PROCESS in PinWhere yabai; do
    for PINWHERE_PID in $(pgrep -x "$PINWHERE_PROCESS" || true); do
      PINWHERE_COMMAND="$(/bin/ps -p "$PINWHERE_PID" -o comm= || true)"
      if [ "$PINWHERE_COMMAND" = "$APP_BINARY" ] || [ "$PINWHERE_COMMAND" = "$APP_CONTENTS/Helpers/yabai" ]; then
        echo "分发输出目录的应用或后台正在运行，请先停止该实例。" >&2
        exit 1
      fi
    done
  done
else
  PINWHERE_JOURNAL="$HOME/Library/Application Support/PinWhere/window-layers.json"
  if [ -f "$PINWHERE_JOURNAL" ] && [ "$(tr -d '[:space:]' < "$PINWHERE_JOURNAL")" != '[]' ]; then
    echo "尚有窗口层级恢复记录，请先在 PinWhere 恢复全部窗口后再重建。" >&2
    exit 1
  fi
  if pgrep -x yabai >/dev/null; then
    echo "请先停止层级后台再重建，避免替换运行中的后端。" >&2
    exit 1
  fi
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
PINWHERE_PATCH_HASH="$(shasum -a 256 "$ROOT_DIR/script/patch_backend.py" | awk '{print $1}')"
if [ ! -x "$ROOT_DIR/.build/backend/yabai" ] || [ ! -f "$ROOT_DIR/.build/backend/patch.sha256" ] || \
   [ "$(cat "$ROOT_DIR/.build/backend/patch.sha256" 2>/dev/null || true)" != "$PINWHERE_PATCH_HASH" ]; then
  "$ROOT_DIR/script/prepare_backend.sh"
fi
swift build --product "$APP_NAME"
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
mkdir -p "$APP_CONTENTS/Helpers"
cp "$ROOT_DIR/.build/backend/yabai" "$APP_CONTENTS/Helpers/yabai"
cp "$ROOT_DIR/.build/backend/yabai-LICENSE.txt" "$APP_CONTENTS/Resources/yabai-LICENSE.txt"
cp "$ROOT_DIR/.build/backend/revision.txt" "$APP_CONTENTS/Resources/backend-revision.txt"
cp "$ROOT_DIR/.build/backend/patch.sha256" "$APP_CONTENTS/Resources/backend-patch.sha256"
cp "$ROOT_DIR/Resources/yabairc" "$APP_CONTENTS/Resources/yabairc"
cp "$ROOT_DIR/script/backend.sh" "$APP_CONTENTS/Resources/backend.sh"
cp "$ROOT_DIR/使用说明.txt" "$APP_CONTENTS/Resources/使用说明.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.txt" "$APP_CONTENTS/Resources/THIRD_PARTY_NOTICES.txt"
chmod 0755 "$APP_CONTENTS/Resources/backend.sh"
chmod 0644 "$APP_CONTENTS/Resources/yabairc"
codesign --force --sign "${PINWHERE_SIGN_IDENTITY:--}" --identifier cn.pinwhere.backend "$APP_CONTENTS/Helpers/yabai"
ICON_SET="$ROOT_DIR/.build/AppIcon.iconset"
if [ ! -f "$APP_CONTENTS/Resources/AppIcon.icns" ] || [ "$ROOT_DIR/script/generate_icon.swift" -nt "$APP_CONTENTS/Resources/AppIcon.icns" ]; then
  swift "$ROOT_DIR/script/generate_icon.swift" "$ICON_SET"
  iconutil -c icns "$ICON_SET" -o "$APP_CONTENTS/Resources/AppIcon.icns"
fi

# 优先使用显式指定的开发签名；本地默认临时签名。
# 保留 codesign 自动生成的身份约束；临时签名重建后可能需要重新授权。
codesign --force --sign "${PINWHERE_SIGN_IDENTITY:--}" --identifier cn.pinwhere.app "$APP_BUNDLE"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  --build-only) echo "应用已构建：$APP_BUNDLE" ;;
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "PinWhere"'
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "cn.pinwhere.app"'
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "PinWhere 已启动。"
    ;;
esac
