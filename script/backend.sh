#!/usr/bin/env bash
set -euo pipefail

PINWHERE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$PINWHERE_ROOT/Info.plist" ] && [ -d "$PINWHERE_ROOT/MacOS" ]; then
  # 打包后位于 PinWhere.app/Contents/Resources，随应用移动，不依赖源码目录。
  PINWHERE_APP="$(cd "$PINWHERE_ROOT/.." && pwd)"
else
  PINWHERE_APP="$PINWHERE_ROOT/dist/PinWhere.app"
fi
PINWHERE_BACKEND="$PINWHERE_APP/Contents/Helpers/yabai"
PINWHERE_STATE="$HOME/Library/Application Support/PinWhere"
PINWHERE_JOURNAL="$PINWHERE_STATE/window-layers.json"
PINWHERE_PIDFILE="$PINWHERE_STATE/backend.pid"
export PINWHERE_BACKEND

has_recovery_records() {
  [ -f "$PINWHERE_JOURNAL" ] || return 1
  # 只把合法空数组视作无记录；损坏、不明格式一律阻止停止后台。
  [ "$(tr -d '[:space:]' < "$PINWHERE_JOURNAL")" != '[]' ]
}

case "${1:---status}" in
  --status)
    /usr/bin/sw_vers
    /usr/bin/csrutil status
    if [ -x "$PINWHERE_BACKEND" ]; then
      "$PINWHERE_BACKEND" --version
      "$PINWHERE_BACKEND" -m query --displays --display >/dev/null && echo "后台已连接。" || echo "后台未连接。"
    else echo "尚未构建后端。"; fi
    if [ -d /Library/ScriptingAdditions/PinWhere.osax ]; then echo "检测到 Dock 扩展文件；是否已生效仍需置顶验证。"; fi
    if has_recovery_records; then echo "有窗口层级恢复记录，请在应用中先恢复。"; fi
    ;;
  --start)
    [ -x "$PINWHERE_BACKEND" ] || { echo "请先构建应用。" >&2; exit 1; }
    if /usr/bin/pgrep -x yabai >/dev/null; then
      echo "已有 yabai 后台，停止操作以免覆盖其他配置。请先核对运行实例。" >&2; exit 1
    fi
    mkdir -p "$PINWHERE_STATE"
    # 普通用户后台；不创建登录服务。首次运行需要单独授予该后端辅助功能权限。
    # 独立会话避免调用终端结束时被回收；不注册登录服务，启动成功必须由 IPC 确认。
    /usr/bin/python3 - "$PINWHERE_BACKEND" "$PINWHERE_APP/Contents/Resources/yabairc" "$PINWHERE_STATE" <<'PY'
from pathlib import Path
import subprocess
import sys
import time

executable, config, state = sys.argv[1:]
state = Path(state)
with (state / 'backend.log').open('ab', buffering=0) as log:
    process = subprocess.Popen([executable, '--config', config], stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
pidfile = state / 'backend.pid'
pidfile.write_text(str(process.pid) + '\n')
pidfile.chmod(0o600)
for attempt in range(30):
    if process.poll() is not None:
        break
    try:
        reply = subprocess.run([executable, '-m', 'query', '--displays', '--display'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
        if reply.returncode == 0:
            print('窗口层级后台已启动并连接。')
            sys.exit(0)
    except subprocess.TimeoutExpired:
        pass
    time.sleep(0.2)
print('后台尚未连接。请检查“设备控制和数据访问”（旧版系统为“辅助功能”）权限。', file=sys.stderr)
print('日志：' + str(state / 'backend.log'), file=sys.stderr)
sys.exit(1)
PY
    ;;
  --stop)
    if has_recovery_records; then echo "尚有恢复记录，请先在 PinWhere 恢复全部层级，再停止后台。" >&2; exit 1; fi
    [ -f "$PINWHERE_PIDFILE" ] || exit 0
    PINWHERE_PID="$(cat "$PINWHERE_PIDFILE")"
    case "$PINWHERE_PID" in ''|*[!0-9]*) echo "PID 记录无效。" >&2; exit 1;; esac
    PINWHERE_COMMAND="$(/bin/ps -p "$PINWHERE_PID" -o comm= || true)"
    if [ "$PINWHERE_COMMAND" = "$PINWHERE_BACKEND" ]; then kill "$PINWHERE_PID"; else echo "后台已退出或 PID 已复用，不发送信号。"; fi
    ;;
  --load-extension)
    [ -x "$PINWHERE_BACKEND" ] || { echo "请先构建应用。" >&2; exit 1; }
    echo "将以管理员权限安装并加载 /Library/ScriptingAdditions/PinWhere.osax。需要已完成 SIP 设置。"
    /usr/bin/sudo "$PINWHERE_BACKEND" --load-sa
    ;;
  --uninstall-extension)
    if has_recovery_records; then echo "请先恢复全部窗口层级。" >&2; exit 1; fi
    echo "将以管理员权限卸载 yabai 的 Dock 扩展（PinWhere 专用目录）。"
    /usr/bin/sudo "$PINWHERE_BACKEND" --uninstall-sa
    ;;
  *) echo "用法：$0 [--status|--start|--stop|--load-extension|--uninstall-extension]" >&2; exit 2;;
esac
