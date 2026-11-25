import Foundation

/// 由随包后端只读探测；未知协议版本不能当作已满足系统条件。
public struct BackendSetupProbe: Codable, Sendable, Equatable {
    public var schema: Int
    public var sipCompatible: Bool
    public var nvramProtectionDisabled: Bool
    public var bootArgumentEnabled: Bool
    public var bootArgumentConfigured: Bool
    public var accessibilityGranted: Bool
    public var extensionInstalled: Bool
    public var extensionReady: Bool

    public init(schema: Int, sipCompatible: Bool, nvramProtectionDisabled: Bool,
                bootArgumentEnabled: Bool, bootArgumentConfigured: Bool, accessibilityGranted: Bool,
                extensionInstalled: Bool, extensionReady: Bool) {
        self.schema = schema; self.sipCompatible = sipCompatible
        self.nvramProtectionDisabled = nvramProtectionDisabled
        self.bootArgumentEnabled = bootArgumentEnabled; self.bootArgumentConfigured = bootArgumentConfigured
        self.accessibilityGranted = accessibilityGranted
        self.extensionInstalled = extensionInstalled; self.extensionReady = extensionReady
    }

    public static func decode(_ data: Data) throws -> Self {
        let probe = try JSONDecoder().decode(Self.self, from: data)
        guard probe.schema == 1 else { throw WindowLayerError.unavailable }
        return probe
    }
}

public enum SetupStep: Sendable {
    case installApp, systemSecurity, bootArgument, appPermission, backendPermission
    case separateSpaces, backendConflict, loadExtension, startBackend, ready
}

public struct SetupContext: Sendable {
    public var probe: BackendSetupProbe
    public var installedInApplications: Bool
    public var appPermission: Bool
    public var separateSpaces: Bool
    public var backendConnected: Bool
    public var conflictingBackend: Bool

    public init(probe: BackendSetupProbe, installedInApplications: Bool, appPermission: Bool,
                separateSpaces: Bool, backendConnected: Bool, conflictingBackend: Bool) {
        self.probe = probe; self.installedInApplications = installedInApplications
        self.appPermission = appPermission; self.separateSpaces = separateSpaces
        self.backendConnected = backendConnected; self.conflictingBackend = conflictingBackend
    }

    public var nextStep: SetupStep {
        if !installedInApplications { return .installApp }
        if !probe.sipCompatible { return .systemSecurity }
        if !probe.bootArgumentEnabled { return .bootArgument }
        if !appPermission { return .appPermission }
        if !probe.accessibilityGranted { return .backendPermission }
        if !separateSpaces { return .separateSpaces }
        if conflictingBackend { return .backendConflict }
        if !probe.extensionReady { return .loadExtension }
        return backendConnected ? .ready : .startBackend
    }

    public var mayStartBackend: Bool { nextStep == .startBackend }
    public var mayLoadExtension: Bool { nextStep == .loadExtension || nextStep == .startBackend || nextStep == .ready }
}

public enum SetupAdministratorCommand {
    public enum Operation: String, Sendable {
        case loadExtension = "--pinwhere-load-extension"
        case reloadExtension = "--pinwhere-reload-extension"
        case enableBootArgument = "--pinwhere-enable-boot-argument"
    }

    public static func script(executable: String, operation: Operation, uid: UInt32) -> String {
        // AppleScript 和 shell 分别转义；路径中的空格、引号和命令替换均保持字面含义。
        let quotedPath = "'" + executable.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command = "/usr/bin/env SUDO_UID=\(uid) \(quotedPath) \(operation.rawValue)"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(literal)\" with administrator privileges"
    }
}

public enum SetupMigrationPolicy {
    public static func mayStopBackend(journal: Data?) -> Bool {
        guard let journal else { return true }
        guard let records = (try? JSONSerialization.jsonObject(with: journal)) as? [Any] else { return false }
        return records.isEmpty
    }

    public static func isPreviousBackend(path: String, bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "cn.pinwhere.app" && path.hasSuffix(".app/Contents/Helpers/yabai")
    }
}
