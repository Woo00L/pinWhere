import Foundation

public struct LayerWindowState: Sendable {
    public let id: UInt32
    public let pid: Int32
    public let level: Int32
    public let generation: UInt64
    public var subLevel: Int32
    public var processStart: TimeInterval

    public init(id: UInt32, pid: Int32, level: Int32, subLevel: Int32, processStart: TimeInterval, generation: UInt64) {
        self.id = id; self.pid = pid; self.level = level; self.subLevel = subLevel; self.processStart = processStart
        self.generation = generation
    }

    public static func decode(_ data: Data, processStart: TimeInterval) throws -> Self {
        struct Reply: Decodable {
            let id: UInt32, pid: Int32, level: Int32, subLevel: Int32
            let generation: UInt64
            enum CodingKeys: String, CodingKey { case id, pid, level; case subLevel = "sub-level"; case generation = "pinwhere-generation" }
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Self(id: reply.id, pid: reply.pid, level: reply.level, subLevel: reply.subLevel, processStart: processStart, generation: reply.generation)
    }
}

public protocol WindowLayerBackend: Sendable {
    func snapshot(id: UInt32) async throws -> LayerWindowState
    func setSubLayer(window: LayerWindowState, layer: String) async throws
}

public enum WindowLayerError: Error, LocalizedError, Equatable {
    case unavailable, timedOut, commandFailed, identityChanged, unsupportedLayer, verificationFailed, restoreFailed, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "窗口层级后端未就绪。请先完成后端设置；不会退回辅助功能抬高。"
        case .timedOut: return "窗口层级后端响应超时，未确认生效。"
        case .commandFailed: return "后端命令失败。请检查后台和 Dock 扩展是否已加载。"
        case .identityChanged: return "原窗口或进程已变化，已拒绝控制，避免误操作其他窗口。"
        case .unsupportedLayer: return "只接受普通层级的原窗口；已有特殊层级的窗口不作修改。"
        case .verificationFailed: return "未能置顶：读取到的实际窗口层级没有变为 above。"
        case .restoreFailed: return "原窗口层级尚未恢复。已保留恢复记录，请恢复后再退出。"
        case .busy: return "正在设置或恢复此窗口，请稍后重试。"
        }
    }
}

public struct WindowLayerLease: Codable, Sendable {
    public let id: UInt32
    public let pid: Int32
    public let processStart: TimeInterval
    public let originalLevel: Int32
    public let originalSubLevel: Int32
    public let generation: UInt64
}

/// 层级写入前持久化恢复记录。命令成功不等于生效，必须读取实际子层级。
public actor WindowLayerManager {
    private let backend: any WindowLayerBackend
    private let journalURL: URL
    private var leases: [WindowLayerLease]?
    private var busy = Set<UInt32>()

    public init(backend: any WindowLayerBackend, journalURL: URL) {
        self.backend = backend; self.journalURL = journalURL
    }

    public func pendingRestores() throws -> [WindowLayerLease] {
        try load()
        return leases ?? []
    }

    private func load() throws {
        guard leases == nil else { return }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            leases = try JSONDecoder().decode([WindowLayerLease].self, from: Data(contentsOf: journalURL))
        } else { leases = [] }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(leases ?? []).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func matches(_ state: LayerWindowState, lease: WindowLayerLease) -> Bool {
        state.id == lease.id && state.pid == lease.pid && state.generation == lease.generation && abs(state.processStart - lease.processStart) < 0.001
    }

    public func pin(id: UInt32, pid: Int32) async throws {
        try load()
        guard !busy.contains(id), leases?.contains(where: { $0.id == id }) != true else { throw WindowLayerError.busy }
        busy.insert(id)
        defer { busy.remove(id) }
        let before = try await backend.snapshot(id: id)
        guard before.id == id, before.pid == pid, before.processStart > 0, before.generation > 0 else { throw WindowLayerError.identityChanged }
        guard before.level == 0, before.subLevel == 0 else { throw WindowLayerError.unsupportedLayer }
        let lease = WindowLayerLease(id: id, pid: pid, processStart: before.processStart,
                                     originalLevel: before.level, originalSubLevel: before.subLevel, generation: before.generation)
        leases?.append(lease)
        do { try save() }
        catch { leases?.removeAll { $0.id == id }; throw error }
        do {
            try await backend.setSubLayer(window: before, layer: "above")
            let after = try await backend.snapshot(id: id)
            guard matches(after, lease: lease) else { throw WindowLayerError.identityChanged }
            guard after.subLevel == 3, after.level == before.level else { throw WindowLayerError.verificationFailed }
        } catch {
            let originalError = error
            // 首次设置失败也可能已经写入系统；不能丢掉恢复责任。
            do { try await restoreLease(lease) }
            catch { throw WindowLayerError.restoreFailed }
            throw originalError
        }
    }

    public func verify(id: UInt32) async throws {
        try load()
        guard let lease = leases?.first(where: { $0.id == id }) else { throw WindowLayerError.identityChanged }
        let state = try await backend.snapshot(id: id)
        guard matches(state, lease: lease) else { throw WindowLayerError.identityChanged }
        guard state.level == lease.originalLevel, state.subLevel == 3 else { throw WindowLayerError.verificationFailed }
    }

    public func restore(id: UInt32) async throws {
        try load()
        guard !busy.contains(id) else { throw WindowLayerError.busy }
        guard let lease = leases?.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        try await restoreLease(lease)
    }

    /// 后台重启丢失代际时，必须让用户重新点选并明确授权恢复；普通恢复不得绕过代际检查。
    public func restoreUserConfirmedWindow(id: UInt32, pid: Int32) async throws {
        try load()
        guard !busy.contains(id) else { throw WindowLayerError.busy }
        guard let index = leases?.firstIndex(where: { $0.id == id }), let previous = leases?[index] else {
            throw WindowLayerError.identityChanged
        }
        busy.insert(id)
        defer { busy.remove(id) }
        let current = try await backend.snapshot(id: id)
        guard current.id == id, current.pid == pid, pid == previous.pid,
              abs(current.processStart - previous.processStart) < 0.001, current.generation > 0 else {
            throw WindowLayerError.identityChanged
        }
        guard current.level == previous.originalLevel, [previous.originalSubLevel, 3].contains(current.subLevel) else {
            throw WindowLayerError.unsupportedLayer
        }
        let confirmed = WindowLayerLease(id: id, pid: pid, processStart: current.processStart,
                                         originalLevel: previous.originalLevel, originalSubLevel: previous.originalSubLevel,
                                         generation: current.generation)
        leases?[index] = confirmed
        do { try save() } catch { leases?[index] = previous; throw error }
        try await restoreLease(confirmed)
    }

    /// 仅在调用方已确认源窗口关闭或原进程退出时清理，不向复用编号的新窗口写入。
    public func forgetClosedWindow(id: UInt32) throws {
        try load()
        guard !busy.contains(id) else { throw WindowLayerError.busy }
        let saved = leases
        leases?.removeAll { $0.id == id }
        do { try save() } catch { leases = saved; throw error }
    }

    private func restoreLease(_ lease: WindowLayerLease) async throws {
        let current = try await backend.snapshot(id: lease.id)
        guard matches(current, lease: lease) else { throw WindowLayerError.identityChanged }
        if current.subLevel != lease.originalSubLevel {
            try await backend.setSubLayer(window: current, layer: "normal")
            let restored = try await backend.snapshot(id: lease.id)
            guard matches(restored, lease: lease) else { throw WindowLayerError.identityChanged }
            guard restored.subLevel == lease.originalSubLevel, restored.level == lease.originalLevel else {
                throw WindowLayerError.restoreFailed
            }
        }
        let saved = leases
        leases?.removeAll { $0.id == lease.id }
        do { try save() } catch { leases = saved; throw error }
    }
}
