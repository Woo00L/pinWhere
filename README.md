# PinWhere

让选中的 macOS 原应用窗口保持置顶，并继续直接点击、输入和滚动。支持从状态栏或 Dock 选择窗口，用图钉拖动原窗口，或单击图钉后让窗口跟随鼠标，再次点击放下，按 Esc 还原位置。

**当前版本需要首次系统设置，无法做到 DMG 拖入“应用程序”后直接使用。重启 Mac 或 Dock 后，也可能需要在 App 内重新加载扩展并完成管理员认证。**

## 版本与使用入口

| 版本 | 代码位置 | 设置方式 |
| --- | --- | --- |
| 0.3.0 | 默认分支 `main` | 使用随包管理脚本加载扩展、启动后台 |
| 0.4.0 | [`codex/guided-setup` 分支](https://github.com/Woo00L/pinWhere/tree/codex/guided-setup) | App 内首次设置引导、后台自动连接、可选登录启动 |

0.4.0 的变更位于 [拉取请求 #1](https://github.com/Woo00L/pinWhere/pull/1)，尚未合并到 `main`。下文的 App 内引导对应 0.4.0；使用 0.3.0 时请阅读该分支的[使用说明](使用说明.txt)。

## 功能

- 状态栏或 Dock 点击图钉选窗，也可从窗口列表选择。
- 修改原窗口的实际子层级，保留原应用的点击、输入和滚动能力，无需屏幕录制权限。
- 拖动图钉移动原窗口；单击跟随鼠标，再次点击放下；Esc 还原位置。
- 取消置顶或正常退出时恢复原层级；异常后保留恢复记录，供再次确认和恢复。
- 0.4.0 提供系统条件检查、安装引导、普通后台自动启动及可选登录启动。

## 使用条件

| 项目 | 条件与限制 |
| --- | --- |
| 硬件 | 当前 App 为 arm64，面向 Apple Silicon；未验证 Intel |
| 系统 | 源码最低声明 macOS 14；目前仅在 macOS 27.0.1（26A434）完成本机验证 |
| 系统保护 | 需要部分关闭 SIP 的文件系统、调试和 NVRAM 保护，并启用 `-arm64e_preview_abi` 启动参数；这会降低整台 Mac 的系统保护 |
| 管理员身份 | 设置启动参数、安装或加载 Dock 扩展时需要系统管理员认证 |
| 窗口控制权限 | PinWhere 和随包 `Contents/Helpers/yabai` 分别授权；macOS 27 为“隐私与安全性 → 设备控制和数据访问”，旧版为“辅助功能” |
| 安装位置 | 先固定到 `/Applications` 或本人 `~/Applications`，再授权 |
| 窗口系统 | 需要开启“显示器具有单独的空间”；目标窗口需提供可用的辅助功能窗口接口 |
| 后台 | 使用随包 yabai 和 PinWhere 专用 Dock 扩展；其他路径的 yabai 可能造成冲突 |
| 签名 | 当前为临时签名开发版，无 Developer ID 和 Apple 公证；下载副本可能被系统拦截，更新或移动后可能需要重新授权 |

菜单、系统安全界面、独立全屏空间，以及所有应用、多显示器和多置顶窗口场景均不在完整验证范围内。系统更新可能导致 Dock 私有接口失效。

## 首次安装与日常使用（0.4.0）

1. 将 `PinWhere.app` 拖入“应用程序”，从固定位置打开，进入首次设置。
2. 按 App 引导在恢复模式中完成 SIP 设置，然后重启；这一项必须本人操作。
3. 在 App 内设置启动参数，按提示重启使其生效。
4. 分别为 PinWhere 和随包后端 yabai 开启窗口控制权限。列表中没有后端时，通过“在访达中显示后端”定位，再在权限列表中添加。
5. 点击“安装或加载扩展…”，确认并完成系统认证。首次安装可能短暂重启 Dock。
6. 条件满足后后台自动启动并连接；显示“已就绪”后即可选窗置顶。
7. 可选开启“登录后打开 PinWhere”。Mac 或 Dock 重启后，若扩展未加载，回到 App 点击加载并认证，随后后台自动连接。

0.4.0 日常运行不需要 Python、Homebrew 或终端命令。首次 SIP 设置仍需恢复模式终端；0.3.0 的后台管理脚本另有 Python 依赖。

安装位置或临时签名变化后，旧权限记录可能无法识别。本机安装时曾需要移除旧 PinWhere 权限记录，再添加“应用程序”中的新副本。

完整的首次设置、升级、恢复和卸载步骤见 [0.4.0 使用说明](https://github.com/Woo00L/pinWhere/blob/codex/guided-setup/%E4%BD%BF%E7%94%A8%E8%AF%B4%E6%98%8E.txt)。

## 已验证范围

2026 年 11 月 6 日与 11 月 8 日在同一台已完成 SIP 和启动参数设置的 Mac 上进行了安装、Dock 重启及整机重启测试：

- 安装阶段读取到原窗口 `sub-level=3`，原应用接收测试输入；图钉拖动改变原窗口位置，取消后清空恢复记录。
- Dock 重启后，App 检测到扩展未加载；通过 App 重新加载后恢复就绪，并可再次置顶。
- 整机重启后，系统日志确认登录自动打开 PinWhere，App 的控制权限保留。
- 本次整机重启后扩展没有自动加载；用户在 App 内加载并完成认证后，后台自动启动，连接查询成功。
- 重启后的置顶、切换 Codex、窗口操作和图钉拖动由用户现场确认正常；该轮交互未由自动化工具独立复现。

这些结果不代表已验证默认完整 SIP 的新电脑从零安装，也不代表其他硬件、系统版本或所有应用均兼容。

## 从源码构建 0.4.0

需要 Xcode 或 Apple 命令行工具、Swift、make、Python 3、curl 和 macOS 系统工具。首次构建联网下载固定版本后端源码并校验哈希；构建本身不会修改系统保护或加载扩展。

```sh
git clone --branch codex/guided-setup https://github.com/Woo00L/pinWhere.git
cd pinWhere
swift test
PINWHERE_OUTPUT_DIR="$PWD/.build/distribution" ./script/build_and_run.sh --build-only
python3 script/check_backend_setup.py .build/distribution/PinWhere.app/Contents/Helpers/yabai
./script/package_dmg.sh "$PWD/.build/distribution/PinWhere.app"
```

App 输出到 `.build/distribution/PinWhere.app`，DMG 及 SHA-256 校验文件输出到 `dist`。上述独立输出目录可避免覆盖默认构建目录；若指定输出目录中的 App 或后台正在运行，构建会停止。

## 恢复与卸载

先在 App 中恢复全部窗口层级，关闭登录启动，再正常退出。强制结束或后台失联后请保留恢复记录；代际不匹配时使用“重新选择原窗口并恢复”。

删除 App 不会自动卸载 Dock 扩展，也不会恢复 SIP 和启动参数。完整回退方式见对应版本的[使用说明](使用说明.txt)。

## 源码结构与第三方许可

- `Sources/PinWhere`：界面、首次设置、权限、选窗、后台与原窗口控制。
- `Sources/PinWhereCore`：窗口身份核对、层级恢复、命令执行、坐标与移动状态机。
- `Tests`：逻辑、身份变化、失败恢复、命令执行和设置策略测试。
- `script`：构建、固定后端源码准备与补丁、后台管理、DMG 打包。

后端使用 yabai 的 macOS 适配源码及本项目补丁。来源、固定版本与 MIT 许可见 [第三方声明](THIRD_PARTY_NOTICES.txt)。
