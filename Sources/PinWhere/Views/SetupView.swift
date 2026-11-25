import AppKit
import PinWhereCore
import SwiftUI

struct SetupView: View {
    @ObservedObject var store: PinStore
    private let recoveryCommand = "csrutil enable --without fs --without debug --without nvram"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置 PinWhere").font(.title2.weight(.semibold))
                    Text("首次完成系统设置，之后由 App 自动检查和连接。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { store.showSetup = false }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let context = store.setupContext { steps(context) }
                    else { ProgressView("正在检查本机条件…") }
                    if let message = store.setupError {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                    }
                    HStack {
                        Button(store.checkingBackend ? "检查中…" : "重新检查并连接", action: store.retrySetup)
                        Button("打开运行日志", action: store.openBackendLog)
                        if store.performingSetup { ProgressView().controlSize(.small) }
                    }.disabled(store.checkingBackend || store.performingSetup)
                    Text("当前为临时签名开发版，仅在 Apple Silicon / macOS 27.0.1 实测。签名更新后可能需要重新授权。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
        }
        .frame(width: 590, height: 660)
        .onAppear { store.checkBackend() }
    }

    @ViewBuilder
    private func steps(_ context: SetupContext) -> some View {
        if context.nextStep == .ready {
            Label("已就绪，可以直接选择原窗口置顶。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.headline)
        }
        step("1", "放入应用程序", complete: context.installedInApplications) {
            Text("先把 PinWhere.app 拖入“应用程序”，再从那里打开。固定路径后再授权。")
            if !context.installedInApplications { Button("打开应用程序文件夹", action: store.openApplications) }
        }
        step("2", "首次调整系统保护", complete: context.probe.sipCompatible) {
            Text("原窗口层级功能依赖 Dock 扩展，需要部分关闭 SIP。这会降低整台 Mac 的系统保护；App 无法代替你在恢复模式确认。")
            if !context.probe.sipCompatible || (!context.probe.bootArgumentEnabled && !context.probe.nvramProtectionDisabled) {
                Text("保存工作并关机 → 按住电源 → 选项 → 继续 → 实用工具 → 终端，执行下方命令。看到成功提示后重启。")
                Text(recoveryCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("复制恢复模式命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryCommand, forType: .string)
                }
            }
            Link("查看 yabai 的系统要求", destination: URL(string: "https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection")!)
        }
        step("3", "设置启动参数并重启", complete: context.probe.bootArgumentEnabled) {
            if context.probe.bootArgumentEnabled { Text("所需启动参数已生效。") }
            else if context.probe.bootArgumentConfigured { Text("参数已经保存。请保存工作并手动重启 Mac，再打开 PinWhere。") }
            else {
                Text("点击设置，保留已有参数并添加所需标记。macOS 将请求管理员认证，成功后请手动重启。")
                Button("设置启动参数…", action: store.enableBootArgument)
                    .disabled(!context.installedInApplications || !context.probe.sipCompatible || !context.probe.nvramProtectionDisabled)
            }
        }
        step("4", "允许控制原窗口", complete: context.appPermission && context.probe.accessibilityGranted) {
            Text("在“隐私与安全性 → \(store.permissionName)”中分别允许 PinWhere 和随包后端 yabai。无需屏幕录制权限。")
            HStack {
                Button(context.appPermission ? "PinWhere 已允许" : "授权 PinWhere", action: store.requestPermission)
                    .disabled(context.appPermission || !context.installedInApplications)
                Button(context.probe.accessibilityGranted ? "后端已允许" : "授权后端", action: store.requestBackendPermission)
                    .disabled(context.probe.accessibilityGranted || !context.installedInApplications)
            }
            HStack {
                Button("打开权限设置", action: store.openPermissionSettings)
                Button("在访达中显示后端", action: store.revealBackend)
            }
            Text("如果列表没有 yabai，点击“＋”，将访达中显示的后端添加进去，再开启开关。")
        }
        if !context.separateSpaces {
            step("5", "允许每个显示器使用单独空间", complete: false) {
                Text("在“桌面与程序坞 → Mission Control”打开“显示器具有单独的空间”，按系统提示退出登录。")
                Button("打开桌面与程序坞", action: store.openDesktopSettings)
            }
        }
        step("6", "加载置顶扩展", complete: context.probe.extensionReady) {
            Text(context.probe.extensionReady ? "本次 Dock 进程中的扩展已就绪。" : "完成前面的步骤后，点击加载并确认管理员认证。首次安装可能短暂重启 Dock。")
            if !context.probe.extensionReady {
                Button("安装或加载扩展…", action: store.loadExtension).disabled(!context.mayLoadExtension)
            }
            Text("重启 Mac 或 Dock 后可能需要再次点击加载并认证；App 不会保存密码或自动提权。")
        }
        if context.conflictingBackend {
            VStack(alignment: .leading, spacing: 8) {
                Label("检测到其他位置的 yabai。旧 PinWhere 可使用下面的迁移按钮，其他窗口管理器需要自行核对。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("退出旧版并停止旧后台…", action: store.migratePreviousVersion)
                    .disabled(store.performingSetup || store.checkingBackend || !store.pins.isEmpty)
            }
        }
        step("7", "自动连接与登录启动", complete: context.nextStep == .ready) {
            Text("条件满足后自动启动并连接后台，不需要终端或 Python。登录启动由你选择开启。")
            Toggle("登录后打开 PinWhere", isOn: Binding(get: { store.loginEnabled || store.loginNeedsApproval }, set: store.setLoginEnabled))
                .disabled(!context.installedInApplications)
            if store.loginNeedsApproval {
                Button("在系统设置中允许登录启动", action: store.openLoginSettings)
            }
        }
    }

    private func step<Content: View>(_ number: String, _ title: String, complete: Bool,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3).foregroundStyle(complete ? .green : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content().font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(store.performingSetup || store.checkingBackend)
    }
}
