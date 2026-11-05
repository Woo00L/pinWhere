import AppKit
import ApplicationServices
import PinWhereCore
import os

@MainActor
final class PinnedWindowController {
    let source: NativeWindow
    var onClose: (() -> Void)?
    var onSourceClosed: (() -> Void)?
    var onBeginMoving: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    private let panel: NSPanel
    private let handle: NativeMoveHandle
    private var movement = MoveGesture()
    private var followTimer: Timer?
    private var catchers: [NSPanel] = []
    private var previousApp: NSRunningApplication?
    private var deactivateObserver: NSObjectProtocol?
    private var layerConfirmed = false
    private var hiddenForSelection = false
    private var stopped = false
    private var lastStatus = ""
    private let logger = Logger(subsystem: "cn.pinwhere.app", category: "NativePin")
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    init(source: NativeWindow) {
        self.source = source
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 68, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "PinWhere 原窗口图钉"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 68, height: 28))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        handle = NativeMoveHandle(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        root.addSubview(handle)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消置顶")!, target: nil, action: nil)
        close.frame = NSRect(x: 40, y: 2, width: 26, height: 24)
        close.isBordered = false
        close.toolTip = "取消这个原窗口的置顶"
        root.addSubview(close)
        panel.contentView = root
        close.target = self
        close.action = #selector(unpin)
        handle.onPress = { [weak self] point in self?.press(at: point) }
        handle.onDrag = { [weak self] point in self?.drag(to: point) }
        handle.onRelease = { [weak self] in self?.release() }
        handle.toolTip = "拖动图钉移动原窗口；单击跟随鼠标，再次点击放下；Esc 还原。"
    }

    func start() throws {
        guard AXIsProcessTrusted() else { throw NativeWindowError.permission }
        layerConfirmed = true
        sync(visible: true)
        status("原窗口层级已确认为 above")
        logger.info("Native sub-layer verified; no capture session")
    }

    func refresh(visible: Bool, obscured: Bool) {
        guard !stopped else { return }
        guard NSRunningApplication(processIdentifier: source.pid)?.isTerminated == false else { onSourceClosed?(); return }
        var role: CFTypeRef?
        let validation = AXUIElementCopyAttributeValue(source.element, kAXRoleAttribute as CFString, &role)
        if validation == .invalidUIElement { onSourceClosed?(); return }
        guard validation == .success, NativeWindows.frame(source.element) != nil else {
            panel.orderOut(nil)
            finishMoving()
            status("已暂停 · 应用暂时无响应")
            return
        }
        let minimized = NativeWindows.value(source.element, kAXMinimizedAttribute) as? Bool ?? false
        let hidden = NSRunningApplication(processIdentifier: source.pid)?.isHidden ?? true
        let available = visible && !minimized && !hidden
        sync(visible: available)
        guard available else {
            finishMoving()
            status("已暂停 · 窗口隐藏、最小化或不在当前桌面")
            return
        }
        if !layerConfirmed { status("未能确认层级 · 请检查后端或取消置顶") }
        else if obscured { status("层级 above · 检测到前方窗口遮挡，待实机核查") }
        else { status("层级 above · 原窗口可直接操作") }
    }

    func setLayerConfirmed(_ confirmed: Bool) {
        layerConfirmed = confirmed
        if !confirmed { finishMoving(); panel.orderOut(nil); status("未能确认层级 · 请检查后端或取消置顶") }
    }

    private func status(_ text: String) {
        guard text != lastStatus else { return }
        logger.info("Pin state: \(text, privacy: .public)")
        lastStatus = text
        onStatus?(text)
    }

    private func sync(visible: Bool) {
        guard visible, !hiddenForSelection, layerConfirmed,
              let rect = NativeWindows.frame(source.element) else { panel.orderOut(nil); return }
        let appRect = PinGeometry.appKitRect(rect, primaryScreenHeight: primaryHeight)
        // 优先把把手放在标题栏上方，屏幕顶端时放到右侧标题栏内。
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(appRect) }) ?? NSScreen.screens.first
        var origin = CGPoint(x: appRect.maxX - 82, y: appRect.maxY + 3)
        if let screen {
            if origin.y + 28 > screen.visibleFrame.maxY { origin.y = appRect.maxY - 31 }
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - 68)
        }
        panel.setFrameOrigin(origin)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func show() {
        if (NativeWindows.value(source.element, kAXMinimizedAttribute) as? Bool) == true {
            let result = AXUIElementSetAttributeValue(source.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else { onError?(NativeWindowError.operation("恢复原窗口", result)); return }
        }
        NSRunningApplication(processIdentifier: source.pid)?.activate(options: [])
        let result = AXUIElementPerformAction(source.element, kAXRaiseAction as CFString)
        if result != .success {
            onError?(NativeWindowError.operation("显示原窗口", result))
        }
        sync(visible: true)
    }

    func hideForSelection() { hiddenForSelection = true; panel.orderOut(nil) }
    func showAfterSelection() { hiddenForSelection = false }
    @objc private func unpin() { onClose?() }

    func stop() {
        stopped = true
        finishMoving()
        panel.orderOut(nil)
        panel.close()
    }

    private func press(at pointer: CGPoint) {
        guard let rect = NativeWindows.frame(source.element) else { return }
        if !movement.isFollowing { onBeginMoving?() }
        let origin = PinGeometry.appKitRect(rect, primaryScreenHeight: primaryHeight).origin
        movement.press(at: pointer, windowOrigin: origin)
    }

    private func drag(to pointer: CGPoint) {
        if let origin = movement.drag(to: pointer) { move(to: origin) }
    }

    private func release() {
        movement.release()
        if movement.isFollowing { beginFollowing() } else { finishMoving() }
    }

    private func move(to origin: CGPoint, constrainToPointerScreen: Bool = true) {
        guard let rect = NativeWindows.frame(source.element) else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first
        var appRect = CGRect(origin: origin, size: rect.size)
        if constrainToPointerScreen, let screen { appRect = PinGeometry.constrainOriginal(appRect, to: screen.visibleFrame) }
        let point = CGPoint(x: appRect.minX, y: primaryHeight - appRect.maxY)
        let result = NativeWindows.setOrigin(point, element: source.element)
        if result != .success {
            finishMoving()
            onError?(NativeWindowError.operation("移动原窗口", result))
            return
        }
        sync(visible: true)
    }

    private func beginFollowing() {
        guard followTimer == nil else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        handle.following = true
        for screen in NSScreen.screens {
            let catcher = MoveCatcherPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            catcher.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            catcher.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            catcher.isOpaque = false
            catcher.hasShadow = false
            catcher.isReleasedWhenClosed = false
            catcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = MoveCatcherView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDrop = { [weak self] point in
                guard let self else { return }
                if let origin = self.movement.follow(to: point) { self.move(to: origin) }
                self.finishMoving(restoreFocus: true)
            }
            view.onCancel = { [weak self] in self?.cancelMoving() }
            catcher.contentView = view
            catcher.makeKeyAndOrderFront(nil)
            catcher.makeFirstResponder(view)
            catchers.append(catcher)
        }
        NSApp.activate(ignoringOtherApps: true)
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                    object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishMoving() }
        }
        followTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let origin = self.movement.follow(to: NSEvent.mouseLocation) else { return }
                self.move(to: origin)
            }
        }
        RunLoop.main.add(followTimer!, forMode: .common)
        logger.info("Original window follows pointer")
    }

    private func cancelMoving() {
        let origin = movement.cancel()
        finishMoving(restoreFocus: true)
        if let origin { move(to: origin, constrainToPointerScreen: false) }
    }

    func finishMoving(restoreFocus: Bool = false) {
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        let restoreApp = previousApp
        previousApp = nil
        movement.drop()
        followTimer?.invalidate()
        followTimer = nil
        handle.following = false
        catchers.forEach { $0.orderOut(nil); $0.close() }
        catchers.removeAll()
        if restoreFocus, NSApp.isActive, restoreApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            restoreApp?.activate(options: [])
        }
    }
}

private final class NativeMoveHandle: NSView {
    var onPress: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onRelease: (() -> Void)?
    var following = false {
        didSet { setAccessibilityLabel(following ? "原窗口正在跟随鼠标" : "移动原窗口"); needsDisplay = true }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("移动原窗口")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { onPress?(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onDrag?(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onRelease?() }
    override func accessibilityPerformPress() -> Bool { onPress?(NSEvent.mouseLocation); onRelease?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        PinArtwork.image(size: 22).draw(in: NSRect(x: 9, y: 3, width: 22, height: 22))
    }
}

private final class MoveCatcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class MoveCatcherView: NSView {
    var onDrop: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onDrop?(window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .closedHand) }
}
