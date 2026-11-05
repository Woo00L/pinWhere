import AppKit
import ApplicationServices
import Combine
import PinWhereCore

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
        guard !checkingBackend else { return }
        checkingBackend = true
        Task {
            defer { checkingBackend = false }
            do {
                pendingRecoveryCount = try await layers.pendingRestores().count
                try await backend.readiness()
                backendConnected = true
                backendStatus = "后台已连接；选窗时检查 Dock 扩展及实际层级。"
            } catch {
                backendConnected = false
                backendStatus = "窗口层级后端未就绪，请先完成后端设置。"
            }
        }
    }

    private func ensureBackend() -> Bool {
        guard backendConnected, !settingLayer, !shuttingDown, !recoveringLayers else {
            errorMessage = "窗口层级后端尚未就绪或正在处理窗口。请先检查后端；不会使用辅助功能抬高代替置顶。"
            checkBackend()
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
