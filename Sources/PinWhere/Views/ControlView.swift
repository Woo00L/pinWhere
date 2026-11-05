import SwiftUI

struct ControlView: View {
    @ObservedObject var store: PinStore
    @State private var windowSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    permission
                    backend
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    pinnedWindows
                    instructions
                }
                .padding(24)
            }
            Divider()
            HStack {
                Toggle("在 Dock 中显示", isOn: $store.showDock)
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Text("原窗口控制 · 无屏幕采集").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 540, idealHeight: 620)
        .sheet(isPresented: $store.showWindowList) { windowList }
    }

    private var header: some View {
        HStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.red.opacity(0.09)).frame(width: 64, height: 64)
                Image(systemName: "pin.fill").font(.system(size: 32, weight: .medium)).foregroundStyle(.red).rotationEffect(.degrees(28))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("PinWhere").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("原窗口层级控制 · 可直接操作").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: store.openWindowList) { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.borderless).help("从窗口列表选择")
                .accessibilityLabel("从窗口列表选择")
                .disabled(store.isSelecting || store.loadingWindowList)
            Button(action: store.beginSelection) {
                Label(store.isSelecting ? "正在选窗…" : "选择窗口", systemImage: "pin.fill")
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(store.isSelecting || store.loadingWindowList || store.showWindowList)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        .padding(24)
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择一个窗口").font(.headline)
                Spacer()
                Button("取消") { store.showWindowList = false }.keyboardShortcut(.cancelAction)
            }
            TextField("搜索应用或窗口标题", text: $windowSearch).textFieldStyle(.roundedBorder)
            List {
                ForEach(store.windowChoices.filter {
                    windowSearch.isEmpty || "\($0.appName) \($0.title)".localizedCaseInsensitiveContains(windowSearch)
                }, id: \.id) { window in
                    Button { store.chooseFromList(window) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "macwindow").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(window.title).lineLimit(1)
                                Text(window.appName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "pin").foregroundStyle(.red)
                        }
                        .padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Text("点选后控制原窗口，可直接点击、输入和滚动。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 500, height: 420)
        .onAppear { windowSearch = "" }
    }

    private var permission: some View {
        HStack(spacing: 12) {
            Image(systemName: store.accessibilityPermission ? "checkmark.shield.fill" : "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 23)).foregroundStyle(store.accessibilityPermission ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.accessibilityPermission ? "\(store.permissionName)权限已允许" : "先允许“\(store.permissionName)”权限").font(.system(size: 13, weight: .medium))
                Text("用于选取和移动原窗口，无需屏幕录制权限。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.accessibilityPermission {
                Button("授权", action: store.requestPermission).buttonStyle(.bordered)
            }
            Button(action: store.openPermissionSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("打开“\(store.permissionName)”设置")
        }
    }

    private var backend: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("窗口层级后端", systemImage: store.backendConnected ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(store.checkingBackend ? "检查中…" : "重新检查", action: store.checkBackend)
                    .disabled(store.checkingBackend)
            }
            Text(store.backendStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            if store.settingLayer { ProgressView("正在设置并核对原窗口层级…").controlSize(.small) }
            if store.pendingRecoveryCount > 0 {
                Text("有 \(store.pendingRecoveryCount) 个窗口层级记录（包含当前置顶）。退出前将恢复。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(store.recoveringLayers ? "正在恢复…" : "恢复全部窗口层级", action: store.recoverPendingLayers)
                    .disabled(store.recoveringLayers || store.settingLayer)
                Button("重新选择原窗口并恢复", action: store.selectWindowForRecovery)
                    .disabled(store.recoveringLayers || store.settingLayer || !store.backendConnected)
                Text("后台重启后无法自动确认窗口时，请亲自重新选择原窗口；点选即确认将该窗口恢复为普通层级。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var pinnedWindows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已选择的窗口").font(.system(size: 14, weight: .semibold))
                Text("\(store.pins.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if !store.pins.isEmpty {
                    Button("全部取消", action: store.removeAll).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if store.pins.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("把一个窗口钉在这里").font(.system(size: 13, weight: .medium))
                    Text("点击「选择窗口」，再用图钉点中目标窗口。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 27)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(store.pins) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "pin.fill").foregroundStyle(.red).font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(item.appName) · \(item.status)").font(.system(size: 10))
                                    .foregroundStyle(item.status.contains("未能") || item.status.contains("失败") ? .orange : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Button { store.show(item.id) } label: { Image(systemName: "macwindow") }.help("显示原窗口")
                            Button { store.remove(item.id) } label: { Image(systemName: "xmark") }.help("取消置顶")
                        }
                        .buttonStyle(.borderless).padding(13)
                        if item.id != store.pins.last?.id { Divider().padding(.leading, 40) }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("轻轻一钉，自由移动").font(.system(size: 13, weight: .semibold))
            instruction("hand.draw", "用图钉移动原窗口", "按住图钉拖动；也可单击图钉跟随鼠标，再次点击放下，Esc 还原位置。")
            instruction("cursorarrow", "直接操作原来的应用", "修改的是原窗口层级；点击、输入和滚动仍交给原应用。取消置顶时恢复层级。")
            instruction("info.circle", "后端未就绪时无法置顶", "需要完成 Dock 扩展设置。只有读取到实际 above 层级才显示图钉；不会自动切回原应用争抢输入。")
            instruction("menubar.rectangle", "随时从状态栏开始", "左键图钉选择窗口，右键打开菜单；Dock 图标也可选窗。")
        }
    }

    private func instruction(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
