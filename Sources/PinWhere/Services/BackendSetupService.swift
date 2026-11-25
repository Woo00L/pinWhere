import AppKit
import Darwin
import PinWhereCore

struct SetupRuntime: Sendable {
    let probe: BackendSetupProbe
    let connected: Bool
    let conflictingPaths: [String]
}

enum SetupError: LocalizedError {
    case conflict, failedToStart, administrator(String)
    var errorDescription: String? {
        switch self {
        case .conflict: return "检测到其他路径的 yabai。请先在旧版恢复全部置顶并退出，不会自动结束其他后台。"
        case .failedToStart: return "后台未能启动。请检查两项窗口控制权限，或打开运行日志。"
        case .administrator(let message): return message
        }
    }
}

/// 普通后台随 App 原生启动。管理员动作使用固定入口，不安装常驻 root 服务。
actor BackendSetupService {
    private let executable = YabaiLayerBackend.executable
    private let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    static let stateDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PinWhere", isDirectory: true)
    static var logURL: URL { stateDirectory.appendingPathComponent("backend.log") }
    private var process: Process?
    private var starting = false

    func inspect() async throws -> SetupRuntime {
        let probe = try await readProbe()
        let paths = try await conflictingPaths()
        let connected = (try? await BackendCommand.run(executable: executable,
            arguments: ["-m", "query", "--displays", "--display"])) != nil
        return SetupRuntime(probe: probe, connected: connected, conflictingPaths: paths)
    }

    private func readProbe() async throws -> BackendSetupProbe {
        try BackendSetupProbe.decode(await BackendCommand.run(executable: executable,
            arguments: ["--pinwhere-setup-status"]))
    }

    private func conflictingPaths() async throws -> [String] {
        // ps 只读本用户进程；使用完整可执行路径，不能把旧版或用户的 yabai 当成本版本。
        let output = try await BackendCommand.run(executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-U", String(getuid()), "-o", "comm="])
        let ownPath = executable.resolvingSymlinksInPath().path
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            let path = String(line).trimmingCharacters(in: .whitespaces)
            guard URL(fileURLWithPath: path).lastPathComponent == "yabai",
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path != ownPath else { return nil }
            return path
        }
    }

    func start() async throws {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        guard try await conflictingPaths().isEmpty else { throw SetupError.conflict }
        if (try? await BackendCommand.run(executable: executable, arguments: ["-m", "query", "--displays", "--display"])) != nil { return }
        // 不因短暂 IPC 故障重复启动同路径后台。
        guard process?.isRunning != true else { throw SetupError.failedToStart }
        let state = Self.stateDirectory
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: Self.logURL)
        defer { try? log.close() }
        try log.seekToEnd()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--config", resources.appendingPathComponent("yabairc").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PINWHERE_BACKEND"] = executable.path
        environment["USER"] = NSUserName()
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = log; child.standardError = log
        try child.run()
        process = child
        let pidfile = state.appendingPathComponent("backend.pid")
        try Data("\(child.processIdentifier)\n".utf8).write(to: pidfile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidfile.path)
        for _ in 0..<25 {
            guard child.isRunning else { break }
            if (try? await BackendCommand.run(executable: executable,
                    arguments: ["-m", "query", "--displays", "--display"], timeout: 0.5)) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SetupError.failedToStart
    }

    func requestBackendPermission() async throws {
        _ = try await BackendCommand.run(executable: executable, arguments: ["--pinwhere-request-access"])
    }

    func stopPreviousPinWhereBackend() async throws {
        let paths = try await conflictingPaths()
        guard !paths.isEmpty else { return }
        // 普通用户的其他 yabai 不属于迁移对象；只接受有明确 App 身份的旧 PinWhere 随包后台。
        for path in paths {
            let binary = URL(fileURLWithPath: path)
            let app = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard SetupMigrationPolicy.isPreviousBackend(path: path, bundleIdentifier: Bundle(url: app)?.bundleIdentifier)
                else { throw SetupError.conflict }
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let previousApps = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: "cn.pinwhere.app")
                .filter { $0.processIdentifier != currentPID }
        }
        // 请求旧版正常退出，让它先恢复窗口。不强制结束，不直接操作旧版控制的窗口。
        for app in previousApps { _ = await MainActor.run { app.terminate() } }
        for _ in 0..<40 {
            if await MainActor.run(body: { previousApps.allSatisfy(\.isTerminated) }) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard await MainActor.run(body: { previousApps.allSatisfy(\.isTerminated) }) else {
            throw SetupError.administrator("旧版未退出，请先在旧版恢复所有窗口并正常退出。")
        }
        let journal = Self.stateDirectory.appendingPathComponent("window-layers.json")
        let records = FileManager.default.fileExists(atPath: journal.path) ? try Data(contentsOf: journal) : nil
        guard SetupMigrationPolicy.mayStopBackend(journal: records) else {
            throw SetupError.administrator("还有窗口恢复记录，不能停止旧后台。请先在旧版恢复全部层级。")
        }
        let output = try await BackendCommand.run(executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-U", String(getuid()), "-o", "pid=,comm="])
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]), paths.contains(String(parts[1])) else { continue }
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  String(cString: buffer) == String(parts[1]) else { continue }
            guard kill(pid, SIGTERM) == 0 else { throw SetupError.conflict }
        }
        for _ in 0..<20 {
            if try await conflictingPaths().isEmpty { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SetupError.conflict
    }

    func performAdministrator(_ operation: SetupAdministratorCommand.Operation) async throws {
        let script = SetupAdministratorCommand.script(executable: executable.path, operation: operation, uid: getuid())
        // 认证等待不阻塞主线程；用户取消时不会自动重试或循环弹窗。
        try await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                throw SetupError.administrator("无法创建系统认证请求。")
            }
            _ = appleScript.executeAndReturnError(&error)
            if let error {
                if error[NSAppleScript.errorNumber] as? Int == -128 {
                    throw SetupError.administrator("已取消管理员认证，系统未就绪时不会启用置顶。")
                }
                throw SetupError.administrator(error[NSAppleScript.errorMessage] as? String ?? "系统设置操作未成功，请重新检查。")
            }
        }.value
    }
}
