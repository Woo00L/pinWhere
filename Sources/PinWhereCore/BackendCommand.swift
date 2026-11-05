import Foundation
import Darwin

public enum BackendCommand {
    /// 后端输出只有单窗 JSON；并行排空管道，避免异常输出填满管道后永久阻塞。
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 2) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try runBlocking(executable: executable, arguments: arguments, timeout: timeout) }.value
    }

    private static func runBlocking(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let state = CommandOutput()
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        try process.run()
        let readers = DispatchGroup()
        for (handle, stderr) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                while let data = try? handle.read(upToCount: 8192), !data.isEmpty {
                    state.append(data, stderr: stderr)
                }
            }
        }
        let expiry = DispatchWorkItem {
            guard process.isRunning else { return }
            state.markTimedOut()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
        process.waitUntilExit()
        expiry.cancel()
        guard readers.wait(timeout: .now() + 0.5) == .success else { throw WindowLayerError.timedOut }
        if state.timedOut { throw WindowLayerError.timedOut }
        guard process.terminationStatus == 0 else { throw WindowLayerError.commandFailed }
        return state.output
    }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var timeout = false
    var output: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    func markTimedOut() { lock.lock(); defer { lock.unlock() }; timeout = true }
    func append(_ data: Data, stderr: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !stderr, bytes.count < 1024 * 1024 { bytes.append(data.prefix(1024 * 1024 - bytes.count)) }
    }
}
