import AppKit
import PinWhereCore
import os

@MainActor
final class WindowPicker {
    private var panels: [NSPanel] = []
    private var targets: [NativeWindow] = []
    private var completion: ((NativeWindow?, Bool) -> Void)?
    private var hoverTimer: Timer?
    private var keyMonitor: Any?
    private var selectedID: CGWindowID?
    private var deactivateObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "cn.pinwhere.app", category: "Picker")
    private let primaryHeight: CGFloat = NSScreen.screens.first?.frame.maxY ?? 0

    func present(windows: [NativeWindow], completion: @escaping (NativeWindow?, Bool) -> Void) {
        self.targets = windows
        self.completion = completion
        logger.info("Window selection started")
        let order = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = order.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        targets.sort { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }

        for screen in NSScreen.screens {
            let panel = PickerPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.acceptsMouseMovedEvents = true
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onChoose = { [weak self] in self?.choose() }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil) }
            return nil
        }
        hoverTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        if let hoverTimer { RunLoop.main.add(hoverTimer, forMode: .common) }
        NSApp.activate(ignoringOtherApps: true)
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                    object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil, restoreFocus: false) }
        }
        updateHover()
    }

    private func updateHover() {
        let point = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        let target = targets.first { $0.frame.contains(cgPoint) }
        selectedID = target?.id
        for panel in panels {
            guard let view = panel.contentView as? PickerView else { continue }
            view.targetRect = target.map {
                let rect = PinGeometry.appKitRect($0.frame, primaryScreenHeight: primaryHeight)
                return rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            }
            let title = target?.title.isEmpty == false ? target?.title : target?.appName
            view.targetTitle = title ?? "请将图钉移到要置顶的窗口"
            view.needsDisplay = true
        }
        PinArtwork.cursor.set()
    }

    private func choose() {
        updateHover()
        guard let id = selectedID, let target = targets.first(where: { $0.id == id }) else { return }
        finish(target)
    }

    func cancel() { finish(nil, restoreFocus: false) }

    private func finish(_ window: NativeWindow?, restoreFocus: Bool = true) {
        guard completion != nil else { return }
        logger.info("Window selection ended; selected: \(window != nil)")
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        NSCursor.arrow.set()
        let callback = completion
        completion = nil
        callback?(window, restoreFocus)
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PickerView: NSView {
    var targetRect: CGRect?
    var targetTitle = ""
    var onChoose: (() -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: PinArtwork.cursor) }
    override func mouseDown(with event: NSEvent) { onChoose?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.10).setFill()
        bounds.fill()
        if let targetRect {
            NSColor.systemRed.withAlphaComponent(0.08).setFill()
            let path = NSBezierPath(roundedRect: targetRect.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            path.fill()
            NSColor.systemRed.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
        let badge = NSRect(x: bounds.midX - 240, y: bounds.maxY - 105, width: 480, height: 58)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 16, yRadius: 16).fill()
        PinArtwork.image(size: 28).draw(in: NSRect(x: badge.minX + 16, y: badge.minY + 16, width: 28, height: 28))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (targetTitle as NSString).draw(in: NSRect(x: badge.minX + 55, y: badge.minY + 30, width: 405, height: 18),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        ("点击选择原窗口 · 可直接操作 · Esc / 右键取消" as NSString).draw(at: NSPoint(x: badge.minX + 55, y: badge.minY + 11),
                                                              withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}
