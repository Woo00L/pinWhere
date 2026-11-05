import Foundation

/// macOS 27 更改了权限入口名称；底层仍使用 Accessibility API。
enum WindowControlPermission {
    static var name: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "设备控制和数据访问" : "辅助功能"
    }
}
