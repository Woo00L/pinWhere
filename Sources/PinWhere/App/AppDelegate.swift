import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = PinStore()
    private var statusItem: NSStatusItem?
    private var controlWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger(subsystem: "cn.pinwhere.app", category: "Startup")
            .notice("Window control permission: \(self.store.accessibilityPermission, privacy: .public)")
        NSApp.setActivationPolicy(store.showDock ? .regular : .accessory)
        installMainMenu()
        installStatusItem()
        store.onDockChanged = { visible in NSApp.setActivationPolicy(visible ? .regular : .accessory) }
        store.onSelectionStarting = { [weak self] in self?.controlWindow?.orderOut(nil) }
        store.onNeedsControl = { [weak self] in self?.showControl() }
        showControl()
        if !UserDefaults.standard.bool(forKey: "setupComplete") { store.openSetup() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { sender.reply(toApplicationShouldTerminate: await store.prepareToQuit()) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { store.shutdown() }
    func applicationDidBecomeActive(_ notification: Notification) { store.checkBackend() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag || controlWindow?.isMiniaturized == true { showControl() }
        else { chooseWindow() }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("选择窗口…", action: #selector(chooseWindow)))
        menu.addItem(item("打开控制窗口", action: #selector(showControl)))
        menu.addItem(item("取消全部置顶", action: #selector(unpinAll)))
        return menu
    }

    @objc func showControl() {
        if controlWindow == nil {
            let hosting = NSHostingController(rootView: ControlView(store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "PinWhere"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 620))
            window.minSize = NSSize(width: 560, height: 570)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            controlWindow = window
        }
        controlWindow?.deminiaturize(nil)
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseWindow() { store.beginSelection() }
    @objc private func unpinAll() { store.removeAll() }
    @objc private func openPermissions() { store.openPermissionSettings() }
    @objc private func openSetup() { showControl(); store.openSetup() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = PinArtwork.image(size: 19, template: true)
            button.toolTip = "PinWhere · 左键选窗 / 右键菜单"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("PinWhere 图钉")
        }
        statusItem = item
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = statusMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else { chooseWindow() }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("选择窗口…", action: #selector(chooseWindow)))
        menu.addItem(item("打开控制窗口", action: #selector(showControl)))
        if !store.pins.isEmpty {
            menu.addItem(.separator())
            let summary = NSMenuItem(title: "已选择 \(store.pins.count) 个窗口", action: nil, keyEquivalent: "")
            menu.addItem(summary)
            menu.addItem(item("取消全部置顶", action: #selector(unpinAll)))
        }
        menu.addItem(.separator())
        menu.addItem(item("首次设置与自动连接…", action: #selector(openSetup)))
        menu.addItem(item("\(store.permissionName)设置…", action: #selector(openPermissions)))
        menu.addItem(item("退出 PinWhere", action: #selector(quit), key: "q"))
        return menu
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(item("关于 PinWhere", action: #selector(showControl)))
        app.addItem(item("打开控制窗口", action: #selector(showControl), key: ","))
        app.addItem(item("首次设置与自动连接…", action: #selector(openSetup)))
        app.addItem(.separator())
        app.addItem(item("退出 PinWhere", action: #selector(quit), key: "q"))
        appItem.submenu = app
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "窗口")
        let select = item("选择窗口…", action: #selector(chooseWindow), key: "p")
        select.keyEquivalentModifierMask = [.command, .shift]
        windows.addItem(select)
        windows.addItem(item("取消全部置顶", action: #selector(unpinAll)))
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
