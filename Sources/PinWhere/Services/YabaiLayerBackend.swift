import AppKit
import Foundation
import PinWhereCore

/// 仅控制窗口子层级；不自行安装、提权、加载扩展或启用平铺。
actor YabaiLayerBackend: WindowLayerBackend {
    static let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yabai")
    private let executable: URL

    init(executable: URL = YabaiLayerBackend.executable) { self.executable = executable }

    func readiness() async throws {
        _ = try await command(["-m", "query", "--displays", "--display"])
    }

    func snapshot(id: UInt32) async throws -> LayerWindowState {
        let data = try await command(["-m", "query", "--windows", "--window", String(id)])
        struct Identity: Decodable { let pid: Int32 }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        let birth = await MainActor.run { NSRunningApplication(processIdentifier: identity.pid)?.launchDate?.timeIntervalSince1970 }
        guard let birth else { throw WindowLayerError.identityChanged }
        return try LayerWindowState.decode(data, processStart: birth)
    }

    func setSubLayer(window: LayerWindowState, layer: String) async throws {
        guard ["above", "normal"].contains(layer) else { throw WindowLayerError.unsupportedLayer }
        let identityAndLayer = "\(window.pid):\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), window.processStart)):\(window.generation):\(layer)"
        _ = try await command(["-m", "window", String(window.id), "--pinwhere-layer", identityAndLayer])
    }

    private func command(_ arguments: [String]) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw WindowLayerError.unavailable }
        return try await BackendCommand.run(executable: executable, arguments: arguments)
    }
}
