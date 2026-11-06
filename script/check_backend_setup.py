#!/usr/bin/env python3
"""只读检查已编译后端的引导协议，并验证普通用户不能调用管理员写入口。"""
import json
import os
import pathlib
import subprocess
import sys

backend = pathlib.Path(sys.argv[1]).resolve()
reply = subprocess.check_output([str(backend), "--pinwhere-setup-status"], timeout=5)
status = json.loads(reply)
assert status["schema"] == 1
for key in ("sipCompatible", "nvramProtectionDisabled", "bootArgumentEnabled",
            "bootArgumentConfigured", "accessibilityGranted", "extensionInstalled", "extensionReady"):
    assert type(status[key]) is bool, f"{key} 必须是 JSON 布尔值，不能用数字冒充"
if os.geteuid() != 0:
    for flag in ("--pinwhere-enable-boot-argument", "--pinwhere-load-extension", "--pinwhere-reload-extension"):
        result = subprocess.run([str(backend), flag], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=5)
        assert result.returncode != 0, f"普通用户不应执行管理员入口：{flag}"
print("原生引导协议及管理员入口边界检查通过。")
