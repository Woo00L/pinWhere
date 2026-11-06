import AppKit
import ApplicationServices
import Combine
import PinWhereCore
import ServiceManagement

struct PinnedWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    var status: String
}

@MainActor
final class PinStore: ObservableObject {
    var permissionName: String { WindowControlPermission.name }
    @Published private(set) var pins: [PinnedWindow] = []
    @Published private(set) var isSelecting = false
    @Published private(set) var accessibilityPermission = AXIsProcessTrusted()
    @Published var errorMessage: String?
    @Published var showWindowList = false
    @Published private(set) var windowChoices: [NativeWindow] = []
    @Published private(set) var loadingWindowList = false
    @Published private(set) var backendConnected = false
    @Published private(set) var backendStatus = "正在检测窗口层级后端…"
    @Published private(set) var checkingBackend = false
    @Published private(set) var setupContext: SetupContext?
    @Published private(set) var setupError: String?
    @Published private(set) var performingSetup = false
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var showSetup = false
    @Published private(set) var pendingRecoveryCount = 0
    @Published private(set) var settingLayer = false
    @Published private(set) var recoveringLayers = false
    @Published var showDock: Bool {
        didSet { UserDefaults.standard.set(showDock, forKey: "showDock"); onDockChanged?(showDock) }
    }
    var onDockChanged: ((Bool) -> Void)?
    var onSelectionStarting: (() -> Void)?
    var onNeedsControl: (() -> Void)?
    private var controllers: [CGWindowID: PinnedWindowController] = [:]
    private var picker: WindowPicker?
    private var timer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var tick = 0
    private let backend = YabaiLayerBackend()
    private let setupService = BackendSetupService()
    private var lastAutomaticStart: Date?
    private let layers: WindowLayerManager
    private var verifyingLayers = false
    private var removing = Set<CGWindowID>()
    private var shuttingDown = false
    private var automaticRestoreAttempted = Set<CGWindowID>()

    init() {
        let journal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PinWhere/window-layers.json")
        layers = WindowLayerManager(backend: backend, journalURL: journal)
        showDock = UserDefaults.standard.object(forKey: "showDock") as? Bool ?? true
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.values.forEach { $0.finishMoving() }
            }
        }
        checkBackend()
    }

    func checkBackend() {
        guard !checkingBackend, !performingSetup, !shuttingDown else { return }
        checkingBackend = true
        Task {
            defer { checkingBackend = false }
            do {
                pendingRecoveryCount = try await layers.pendingRestores().count
                accessibilityPermission = AXIsProcessTrusted()
                var runtime = try await setupService.inspect()
                var context = makeSetupContext(runtime)
                setupContext = context
                // 自动启动只发生在全部前提满足时；失败后退避，避免不断重启或弹窗。
                if context.mayStartBackend, lastAutomaticStart.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
                    lastAutomaticStart = Date()
                    try await setupService.start()
                    runtime = try await setupService.inspect()
                    context = makeSetupContext(runtime)
                }
                setupContext = context
                backendConnected = context.nextStep == .ready
                if backendConnected { UserDefaults.standard.set(true, forKey: "setupComplete") }
                backendStatus = setupSummary(context.nextStep)
                setupError = nil
                loginEnabled = SMAppService.mainApp.status == .enabled
                loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
            } catch {
                backendConnected = false
                setupError = error.localizedDescription
                backendStatus = "尚未就绪，请打开首次设置检查。"
            }
        }
    }

    private func makeSetupContext(_ runtime: SetupRuntime) -> SetupContext {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return SetupContext(probe: runtime.probe,
            installedInApplications: app == "/Applications" || app == userApplications,
            appPermission: accessibilityPermission,
            separateSpaces: !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false),
            backendConnected: runtime.connected, conflictingBackend: !runtime.conflictingPaths.isEmpty)
    }

    private func setupSummary(_ step: SetupStep) -> String {
        switch step {
        case .installApp: return "请先将 App 放入“应用程序”，再从固定位置打开并授权。"
        case .systemSecurity: return "首次需要在恢复模式调整系统保护，请查看设置引导。"
        case .bootArgument: return "启动参数尚未生效，请在引导中设置并手动重启。"
        case .appPermission: return "请允许 PinWhere 的“\(permissionName)”权限。"
        case .backendPermission: return "请单独允许随包后端的“\(permissionName)”权限。"
        case .separateSpaces: return "请在“桌面与程序坞”开启“显示器具有单独的空间”。"
        case .backendConflict: return "检测到其他路径的 yabai；不会自动覆盖或结束它。"
        case .loadExtension: return "请点击加载扩展并完成系统管理员认证，无需终端命令。"
        case .startBackend: return "后台尚未连接，正在等待自动启动或手动重试。"
        case .ready: return "已就绪，后台自动连接；可选择原窗口置顶。"
        }
    }

    func openSetup() { showSetup = true; checkBackend() }

    func requestBackendPermission() {
        guard !performingSetup, !checkingBackend else { return }
        performingSetup = true
        Task {
            do { try await setupService.requestBackendPermission(); openPermissionSettings() }
            catch { setupError = error.localizedDescription }
            performingSetup = false
            checkBackend()
        }
    }

    func revealBackend() { NSWorkspace.shared.activateFileViewerSelecting([YabaiLayerBackend.executable]) }
    func openApplications() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
    func openBackendLog() { NSWorkspace.shared.open(BackendSetupService.logURL) }
    func openDesktopSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }

    func loadExtension() {
        guard let context = setupContext, context.mayLoadExtension,
              context.probe.extensionInstalled || (pins.isEmpty && pendingRecoveryCount == 0) else {
            setupError = "请先完成前面的设置并恢复全部置顶，扩展安装可能重启 Dock。"; return
        }
        let alert = NSAlert()
        alert.messageText = "安装或加载窗口置顶扩展？"
        let reloading = !pins.isEmpty || pendingRecoveryCount > 0
        alert.informativeText = reloading
            ? "将重新加载已安装的匹配扩展，以便恢复窗口层级。不会重新安装或主动重启 Dock，随后由 macOS 请求管理员认证。"
            : "将加载 PinWhere 专用 Dock 扩展。首次安装可能短暂重启 Dock，随后由 macOS 请求管理员认证。"
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performAdministrator(reloading ? .reloadExtension : .loadExtension)
    }

    func enableBootArgument() {
        guard let context = setupContext, context.installedInApplications, context.probe.sipCompatible,
              context.probe.nvramProtectionDisabled else { return }
        let alert = NSAlert()
        alert.messageText = "设置置顶扩展所需的启动参数？"
        alert.informativeText = "将保留已有参数，并添加 -arm64e_preview_abi。成功后需要你保存工作并手动重启 Mac，App 不会自动重启。"
        alert.addButton(withTitle: "设置"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performAdministrator(.enableBootArgument)
    }

    private func performAdministrator(_ operation: SetupAdministratorCommand.Operation) {
        guard !performingSetup, !checkingBackend else { return }
        performingSetup = true; setupError = nil
        Task {
            do { try await setupService.performAdministrator(operation) }
            catch { setupError = error.localizedDescription }
            performingSetup = false
            // 失败或用户取消后保留错误，不让只读检查把原因清掉。
            if setupError == nil { lastAutomaticStart = nil; checkBackend() }
        }
    }

    func retrySetup() { lastAutomaticStart = nil; checkBackend() }

    func migratePreviousVersion() {
        guard !performingSetup, !checkingBackend, pins.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "退出旧版并停止旧后台？"
        alert.informativeText = "将请求旧 PinWhere 正常退出，以先恢复它的置顶窗口。仅在恢复记录为空时停止旧版随包后台，不会结束其他 yabai。"
        alert.addButton(withTitle: "迁移旧版"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performingSetup = true; setupError = nil
        Task {
            do { try await setupService.stopPreviousPinWhereBackend() }
            catch { setupError = error.localizedDescription }
            performingSetup = false
            if setupError == nil { lastAutomaticStart = nil; checkBackend() }
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        } catch { setupError = "登录启动设置未成功：\(error.localizedDescription)" }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func ensureBackend() -> Bool {
        guard backendConnected, !settingLayer, !shuttingDown, !recoveringLayers else {
            errorMessage = "窗口置顶尚未就绪或正在处理窗口。请打开设置检查，条件满足后会自动连接。"
            checkBackend()
            if !backendConnected { showSetup = true }
            onNeedsControl?()
            return false
        }
        return true
    }

    private func ensurePermission() -> Bool {
        accessibilityPermission = AXIsProcessTrusted()
        guard accessibilityPermission else {
            errorMessage = "需要“\(permissionName)”权限以选取和移动原窗口。不需要屏幕录制权限。"
            onNeedsControl?()
            return false
        }
        return true
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityPermission = AXIsProcessTrustedWithOptions(options)
        if !accessibilityPermission { openPermissionSettings() }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func beginSelection() {
        guard !isSelecting, !loadingWindowList, !showWindowList, ensureBackend(), ensurePermission() else { return }
        errorMessage = nil
        do {
            let windows = try NativeWindows.list()
            guard !windows.isEmpty else { throw NativeWindowError.noWindows }
            let previousApp = NSWorkspace.shared.frontmostApplication
            isSelecting = true
            controllers.values.forEach { $0.finishMoving(); $0.hideForSelection() }
            onSelectionStarting?()
            let picker = WindowPicker()
            self.picker = picker
            picker.present(windows: windows) { [weak self] window, restoreFocus in
                guard let self else { return }
                self.isSelecting = false
                self.picker = nil
                self.controllers.values.forEach { $0.showAfterSelection() }
                if restoreFocus, previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previousApp?.activate(options: [])
                }
                if let window { self.pin(window) }
                else if restoreFocus { self.onNeedsControl?() }
            }
        } catch { fail(error) }
    }

    func openWindowList() {
        guard !isSelecting, !loadingWindowList, !showWindowList, ensureBackend(), ensurePermission() else { return }
        errorMessage = nil
        loadingWindowList = true
        defer { loadingWindowList = false }
        do {
            windowChoices = try NativeWindows.list().sorted { $0.appName < $1.appName }
            guard !windowChoices.isEmpty else { throw NativeWindowError.noWindows }
            showWindowList = true
        } catch { fail(error) }
    }

    func chooseFromList(_ source: NativeWindow) {
        showWindowList = false
        windowChoices = []
        controllers.values.forEach { $0.finishMoving() }
        onSelectionStarting?()
        pin(source)
    }

    private func pin(_ window: NativeWindow) {
        if let controller = controllers[window.id] { controller.show(); return }
        guard !settingLayer, !shuttingDown, !recoveringLayers else { return }
        settingLayer = true
        Task {
            defer { settingLayer = false }
            do {
                if NativeWindows.hasModalWindow(for: window) { throw NativeWindowError.unsupported }
                try await layers.pin(id: window.id, pid: window.pid)
                if shuttingDown { try await layers.restore(id: window.id); return }
                try attach(window)
                pendingRecoveryCount = try await layers.pendingRestores().count
            } catch {
                if controllers[window.id] == nil { try? await layers.restore(id: window.id) }
                pendingRecoveryCount = (try? await layers.pendingRestores().count) ?? pendingRecoveryCount
                fail(error)
            }
        }
    }

    private func attach(_ window: NativeWindow) throws {
        let controller = PinnedWindowController(source: window)
        let id = window.id
        controller.onClose = { [weak self] in self?.remove(id) }
        controller.onSourceClosed = { [weak self] in self?.remove(id, sourceClosed: true) }
        controller.onStatus = { [weak self] status in
            guard let self, let index = self.pins.firstIndex(where: { $0.id == id }) else { return }
            self.pins[index].status = status
        }
        controller.onBeginMoving = { [weak self] in
            self?.controllers.filter { $0.key != id }.values.forEach { $0.finishMoving() }
        }
        controller.onError = { [weak self] error in self?.fail(error) }
        controllers[id] = controller
        pins.append(PinnedWindow(id: id, title: window.title, appName: window.appName, status: "正在连接原窗口"))
        do { try controller.start() }
        catch {
            controllers.removeValue(forKey: id)?.stop()
            pins.removeAll { $0.id == id }
            throw error
        }
    }

    private func fail(_ error: Error) { errorMessage = error.localizedDescription; onNeedsControl?() }
    func remove(_ id: CGWindowID, sourceClosed: Bool = false, automatic: Bool = false) {
        guard !recoveringLayers, !shuttingDown else { return }
        guard removing.insert(id).inserted else { return }
        Task {
            defer { removing.remove(id) }
            do {
                if sourceClosed { try await layers.forgetClosedWindow(id: id) }
                else { try await layers.restore(id: id) }
                controllers.removeValue(forKey: id)?.stop()
                pins.removeAll { $0.id == id }
                automaticRestoreAttempted.remove(id)
                pendingRecoveryCount = try await layers.pendingRestores().count
            } catch {
                if automatic { errorMessage = error.localizedDescription; controllers[id]?.setLayerConfirmed(false) }
                else { fail(error) }
            }
        }
    }
    func removeAll() { for id in Array(controllers.keys) { remove(id) } }
    func show(_ id: CGWindowID) { controllers[id]?.show() }

    func prepareToQuit() async -> Bool {
        guard !settingLayer, removing.isEmpty, !recoveringLayers else {
            errorMessage = "正在设置或恢复窗口，请完成后再退出。"; onNeedsControl?(); return false
        }
        shuttingDown = true
        picker?.cancel(); picker = nil
        let succeeded = await recoverLayers()
        guard succeeded else { shuttingDown = false; return false }
        controllers.values.forEach { $0.stop() }
        controllers.removeAll(); pins.removeAll()
        shutdown()
        return true
    }

    func recoverPendingLayers() {
        guard !recoveringLayers, !settingLayer, removing.isEmpty, !shuttingDown else { return }
        recoveringLayers = true
        Task { defer { recoveringLayers = false }; _ = await recoverLayers() }
    }

    func selectWindowForRecovery() {
        guard !isSelecting, !showWindowList, !settingLayer, !recoveringLayers, removing.isEmpty,
              ensureBackend(), ensurePermission() else { return }
        recoveringLayers = true
        Task { [self] in
            do {
                let leases = try await layers.pendingRestores()
                let windows = try NativeWindows.list().filter { window in
                    leases.contains { $0.id == window.id && $0.pid == window.pid }
                }
                guard !windows.isEmpty else { throw NativeWindowError.noWindows }
                isSelecting = true
                controllers.values.forEach { $0.finishMoving(); $0.hideForSelection() }
                onSelectionStarting?()
                let selector = WindowPicker()
                picker = selector
                selector.present(windows: windows) { [weak self] source, _ in
                    guard let self else { return }
                    self.isSelecting = false
                    self.picker = nil
                    self.controllers.values.forEach { $0.showAfterSelection() }
                    Task {
                        defer { self.recoveringLayers = false; self.onNeedsControl?() }
                        guard let source else { return }
                        do {
                            try await self.layers.restoreUserConfirmedWindow(id: source.id, pid: source.pid)
                            self.controllers.removeValue(forKey: source.id)?.stop()
                            self.pins.removeAll { $0.id == source.id }
                            self.automaticRestoreAttempted.remove(source.id)
                            self.pendingRecoveryCount = try await self.layers.pendingRestores().count
                            self.errorMessage = nil
                        } catch { self.fail(error) }
                    }
                }
            } catch { recoveringLayers = false; fail(error) }
        }
    }

    private func recoverLayers() async -> Bool {
        do {
            for lease in try await layers.pendingRestores() {
                let application = NSRunningApplication(processIdentifier: lease.pid)
                if application == nil || application?.isTerminated == true {
                    try await layers.forgetClosedWindow(id: lease.id)
                } else {
                    guard let birth = application?.launchDate?.timeIntervalSince1970 else {
                        throw WindowLayerError.identityChanged
                    }
                    if abs(birth - lease.processStart) >= 0.001 {
                        try await layers.forgetClosedWindow(id: lease.id)
                        controllers.removeValue(forKey: lease.id)?.stop()
                        pins.removeAll { $0.id == lease.id }
                        continue
                    }
                    let exists = NativeWindows.windowInfo(onScreenOnly: false).contains {
                        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == lease.id &&
                        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == lease.pid
                    }
                    if exists { try await layers.restore(id: lease.id) }
                    else { try await layers.forgetClosedWindow(id: lease.id) }
                }
                controllers.removeValue(forKey: lease.id)?.stop()
                pins.removeAll { $0.id == lease.id }
            }
            pendingRecoveryCount = 0
            return true
        } catch { fail(error); return false }
    }

    func shutdown() {
        timer?.invalidate()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        controllers.values.forEach { $0.stop() }
    }

    private func refresh() {
        tick += 1
        if tick % 150 == 0 { checkBackend() }
        if tick % 10 == 0 { accessibilityPermission = AXIsProcessTrusted() }
        guard !controllers.isEmpty else { return }
        guard accessibilityPermission else {
            controllers.values.forEach { $0.finishMoving(); $0.hideForSelection() }
            errorMessage = "“\(permissionName)”权限已被撤销，移动已暂停；请取消置顶以恢复窗口层级。"
            return
        }
        let order = NativeWindows.windowInfo(onScreenOnly: true).compactMap { info -> OrderedWindow? in
            guard let id = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return OrderedWindow(id: id.uint32Value, pid: pid.int32Value, frame: frame,
                                 layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
        let ids = Set(order.map(\.id))
        for (id, controller) in Array(controllers) {
            if tick % 5 == 0, !automaticRestoreAttempted.contains(id), !removing.contains(id), !recoveringLayers, !shuttingDown,
               NativeWindows.hasModalWindow(for: controller.source) {
                controller.finishMoving()
                automaticRestoreAttempted.insert(id)
                controller.setLayerConfirmed(false)
                errorMessage = "检测到原应用对话框，正在取消置顶并恢复层级，避免遮挡对话框。处理完后可重新选择窗口。"
                remove(id, automatic: true)
                continue
            }
            controller.refresh(visible: ids.contains(id),
                               obscured: PinOrderPolicy.hasOrdinaryObstruction(targetID: id, frontToBack: order))
        }
        if tick % 20 == 0, !verifyingLayers, !settingLayer, removing.isEmpty, !recoveringLayers, !shuttingDown {
            verifyingLayers = true
            let ids = Array(controllers.keys)
            Task {
                defer { verifyingLayers = false }
                for id in ids {
                    if automaticRestoreAttempted.contains(id) { continue }
                    do { try await layers.verify(id: id); controllers[id]?.setLayerConfirmed(true) }
                    catch { controllers[id]?.setLayerConfirmed(false) }
                }
            }
        }
    }
}
