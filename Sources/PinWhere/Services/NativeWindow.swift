import AppKit
import ApplicationServices
import Darwin

struct NativeWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let frame: CGRect
    let element: AXUIElement
}

enum NativeWindowError: LocalizedError {
    case permission, noWindows, unsupported, operation(String, AXError)
    var errorDescription: String? {
        switch self {
        case .permission: return "需要“\(WindowControlPermission.name)”权限，才能控制原窗口。"
        case .noWindows: return "未找到可控制的普通窗口。请先打开目标应用窗口。"
        case .unsupported: return "这个窗口没有提供可用的辅助功能控制接口。"
        case let .operation(name, error): return "\(name)失败（辅助功能错误 \(error.rawValue)）。"
        }
    }
}

@MainActor
enum NativeWindows {
    // 只用此只读接口将 AX 窗口精确对应到 WindowServer ID，避免同名窗口误选。
    // 此服务只负责定位和移动；子层级写入由独立后端处理。
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
    private static let windowIDFunction: WindowIDFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func setOrigin(_ point: CGPoint, element: AXUIElement) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    static func windowInfo(onScreenOnly: Bool) -> [[String: Any]] {
        CGWindowListCopyWindowInfo([onScreenOnly ? .optionOnScreenOnly : .optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    static func list() throws -> [NativeWindow] {
        guard AXIsProcessTrusted() else { throw NativeWindowError.permission }
        // 系统对象的超时用于整个进程；应用/窗口对象的设置不会相互继承。
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.08)
        let infos = windowInfo(onScreenOnly: true).filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 &&
            ($0[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier
        }
        var result: [NativeWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            let appInfos = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }
            guard !appInfos.isEmpty else { continue }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.25)
            guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for element in windows {
                AXUIElementSetMessagingTimeout(element, 0.08)
                guard (value(element, kAXRoleAttribute) as? String) == kAXWindowRole,
                      (value(element, kAXMinimizedAttribute) as? Bool) != true,
                      let frame = frame(element), frame.width > 60, frame.height > 40 else { continue }
                var id: CGWindowID = 0
                // 无法精确取得 ID 时不按标题或位置猜测，以免控制另一桌面的同名窗口。
                guard windowIDFunction?(element, &id) == AXError.success.rawValue, id != 0 else { continue }
                guard appInfos.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else { continue }
                let title = value(element, kAXTitleAttribute) as? String ?? ""
                result.append(NativeWindow(id: id, pid: app.processIdentifier,
                                           title: title.isEmpty ? "无标题窗口" : title,
                                           appName: app.localizedName ?? "应用", frame: frame, element: element))
            }
        }
        return result
    }

    static func hasModalWindow(for source: NativeWindow) -> Bool {
        if let children = value(source.element, kAXChildrenAttribute) as? [AXUIElement],
           children.contains(where: { (value($0, kAXRoleAttribute) as? String) == kAXSheetRole }) { return true }
        let application = AXUIElementCreateApplication(source.pid)
        guard let focused = value(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = focused as! AXUIElement
        let subrole = value(window, kAXSubroleAttribute) as? String
        return (value(window, kAXModalAttribute) as? Bool) == true || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
    }
}
