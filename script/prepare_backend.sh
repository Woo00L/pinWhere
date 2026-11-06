#!/usr/bin/env bash
set -euo pipefail

# 仅下载及编译固定源码；不安装服务、不加载 Dock 扩展、不修改 SIP。
PINWHERE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINWHERE_REV="ad8d5adfdc39c76399599ae79a264f2525f6ca5e"
PINWHERE_ARCHIVE_HASH="ad3bd2b819144d49a6c359bd69bd10cd58528d96d068be4c30bab1cd4aaf9c23"
PINWHERE_SOURCE="$PINWHERE_ROOT/.build/backend-source"
PINWHERE_ARTIFACT="$PINWHERE_ROOT/.build/backend"
mkdir -p "$PINWHERE_ARTIFACT"
if [ ! -f "$PINWHERE_ARTIFACT/source.tar.gz" ]; then
  curl --fail --location --retry 2 --max-time 120 \
    "https://api.github.com/repos/AhsanFazal/yabai/tarball/$PINWHERE_REV" \
    -o "$PINWHERE_ARTIFACT/source.tar.gz"
fi
PINWHERE_ACTUAL_HASH="$(shasum -a 256 "$PINWHERE_ARTIFACT/source.tar.gz" | awk '{print $1}')"
if [ "$PINWHERE_ACTUAL_HASH" != "$PINWHERE_ARCHIVE_HASH" ]; then
  echo "源码压缩包校验失败，停止构建。" >&2
  exit 1
fi
mkdir -p "$PINWHERE_SOURCE"
tar -xzf "$PINWHERE_ARTIFACT/source.tar.gz" --strip-components=1 -C "$PINWHERE_SOURCE"
python3 "$PINWHERE_ROOT/script/patch_backend.py" "$PINWHERE_SOURCE"
make -C "$PINWHERE_SOURCE" install
cp "$PINWHERE_SOURCE/bin/yabai" "$PINWHERE_ARTIFACT/yabai"
cp "$PINWHERE_SOURCE/LICENSE.txt" "$PINWHERE_ARTIFACT/yabai-LICENSE.txt"
codesign --force --sign - --identifier cn.pinwhere.backend "$PINWHERE_ARTIFACT/yabai"
printf '%s\n' "$PINWHERE_REV" > "$PINWHERE_ARTIFACT/revision.txt"
cat "$PINWHERE_ROOT/script/patch_backend.py" "$PINWHERE_ROOT/script/backend_setup.m" | shasum -a 256 | awk '{print $1}' > "$PINWHERE_ARTIFACT/patch.sha256"
echo "层级后端已构建，尚未启动或加载扩展。"
