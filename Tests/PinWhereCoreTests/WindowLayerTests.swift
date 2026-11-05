import XCTest
@testable import PinWhereCore

final class WindowLayerTests: XCTestCase {
    private func journal() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    func testSuccessfulCommandWithoutActualLayerChangeIsRejected() async throws {
        let backend = TestLayerBackend(ignoreWrites: true)
        let manager = WindowLayerManager(backend: backend, journalURL: journal())
        do {
            try await manager.pin(id: 42, pid: 100)
            XCTFail("命令成功但层级不变，必须拒绝置顶")
        } catch { XCTAssertEqual(error as? WindowLayerError, .verificationFailed) }
        let leases = try await manager.pendingRestores()
        XCTAssertTrue(leases.isEmpty)
    }

    func testPinAndUnpinChangeActualLayerAndRemoveRecoveryRecord() async throws {
        let url = journal()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = TestLayerBackend()
        let manager = WindowLayerManager(backend: backend, journalURL: url)
        try await manager.pin(id: 42, pid: 100)
        let state = try await backend.snapshot(id: 42)
        XCTAssertEqual(state.subLevel, 3)
        let saved = try JSONDecoder().decode([WindowLayerLease].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.first?.id, 42)
        try await manager.restore(id: 42)
        let restored = try await backend.snapshot(id: 42)
        XCTAssertEqual(restored.subLevel, 0)
        let remaining = try await manager.pendingRestores()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReusedWindowIDNeverChangesAnotherProcess() async throws {
        let backend = TestLayerBackend(pid: 101)
        let manager = WindowLayerManager(backend: backend, journalURL: journal())
        do { try await manager.pin(id: 42, pid: 100); XCTFail("PID 不匹配必须拒绝") }
        catch { XCTAssertEqual(error as? WindowLayerError, .identityChanged) }
        let state = try await backend.snapshot(id: 42)
        XCTAssertEqual(state.subLevel, 0)
    }

    func testWindowIDReusedBetweenSnapshotAndWriteIsRejected() async throws {
        let backend = TestLayerBackend(reuseOnWrite: true)
        let manager = WindowLayerManager(backend: backend, journalURL: journal())
        do { try await manager.pin(id: 42, pid: 100); XCTFail("写入边界必须重新核对 PID") }
        catch { XCTAssertEqual(error as? WindowLayerError, .restoreFailed) }
        let state = try await backend.snapshot(id: 42)
        XCTAssertEqual(state.pid, 200)
        XCTAssertEqual(state.subLevel, 0)
    }

    func testRestoreAfterAppRestartUsesJournalAndChecksProcessBirth() async throws {
        let url = journal()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = TestLayerBackend()
        try await WindowLayerManager(backend: backend, journalURL: url).pin(id: 42, pid: 100)
        await backend.changeProcessBirth(to: 200)
        let restarted = WindowLayerManager(backend: backend, journalURL: url)
        do { try await restarted.restore(id: 42); XCTFail("进程重用后不得恢复新进程") }
        catch { XCTAssertEqual(error as? WindowLayerError, .identityChanged) }
        let state = try await backend.snapshot(id: 42)
        XCTAssertEqual(state.subLevel, 3)
    }

    func testFailedRestoreKeepsJournalForRetry() async throws {
        let url = journal()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = TestLayerBackend()
        let manager = WindowLayerManager(backend: backend, journalURL: url)
        try await manager.pin(id: 42, pid: 100)
        await backend.setIgnoreWrites(true)
        do { try await manager.restore(id: 42); XCTFail("恢复未生效必须报错") }
        catch { XCTAssertEqual(error as? WindowLayerError, .restoreFailed) }
        let leases = try await manager.pendingRestores()
        XCTAssertEqual(leases.count, 1)
    }

    func testSameProcessReusedWindowCannotUseOldLease() async throws {
        let url = journal()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = TestLayerBackend()
        let manager = WindowLayerManager(backend: backend, journalURL: url)
        try await manager.pin(id: 42, pid: 100)
        await backend.replaceWindowInSameProcess()
        do { try await manager.restore(id: 42); XCTFail("同进程中新窗口不得套用旧记录") }
        catch { XCTAssertEqual(error as? WindowLayerError, .identityChanged) }
        let state = try await backend.snapshot(id: 42)
        XCTAssertEqual(state.subLevel, 0)
    }

    func testDaemonRestartNeedsExplicitUserSelectionBeforeRestore() async throws {
        let url = journal()
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = TestLayerBackend()
        let manager = WindowLayerManager(backend: backend, journalURL: url)
        try await manager.pin(id: 42, pid: 100)
        await backend.restartGeneration()
        do { try await manager.restore(id: 42); XCTFail("后台重启后不得自动认作旧窗口") }
        catch { XCTAssertEqual(error as? WindowLayerError, .identityChanged) }
        try await manager.restoreUserConfirmedWindow(id: 42, pid: 100)
        let state = try await backend.snapshot(id: 42)
        XCTAssertEqual(state.subLevel, 0)
        let leases = try await manager.pendingRestores()
        XCTAssertTrue(leases.isEmpty)
    }

    func testYabaiReplyRequiresActualNumericLayerAndExactWindow() throws {
        let valid = Data(#"{"id":42,"pid":100,"level":0,"sub-level":3,"sub-layer":"above","pinwhere-generation":123}"#.utf8)
        let state = try LayerWindowState.decode(valid, processStart: 100)
        XCTAssertEqual(state.subLevel, 3)
        XCTAssertThrowsError(try LayerWindowState.decode(Data(#"{"id":42,"pid":100,"sub-layer":"above"}"#.utf8), processStart: 100))
    }
}

private actor TestLayerBackend: WindowLayerBackend {
    var state: LayerWindowState
    var ignoreWrites: Bool
    var reuseOnWrite: Bool
    init(pid: Int32 = 100, ignoreWrites: Bool = false, reuseOnWrite: Bool = false) {
        state = LayerWindowState(id: 42, pid: pid, level: 0, subLevel: 0, processStart: 100, generation: 123)
        self.ignoreWrites = ignoreWrites
        self.reuseOnWrite = reuseOnWrite
    }
    func snapshot(id: UInt32) async throws -> LayerWindowState { state }
    func setSubLayer(window: LayerWindowState, layer: String) async throws {
        if reuseOnWrite {
            state = LayerWindowState(id: 42, pid: 200, level: 0, subLevel: 0, processStart: 200, generation: 124)
            reuseOnWrite = false
        }
        guard state.pid == window.pid, state.generation == window.generation, abs(state.processStart - window.processStart) < 0.001 else { throw WindowLayerError.identityChanged }
        if !ignoreWrites { state.subLevel = layer == "above" ? 3 : 0 }
    }
    func changeProcessBirth(to value: TimeInterval) { state.processStart = value }
    func setIgnoreWrites(_ value: Bool) { ignoreWrites = value }
    func replaceWindowInSameProcess() {
        state = LayerWindowState(id: 42, pid: 100, level: 0, subLevel: 0, processStart: 100, generation: 124)
    }
    func restartGeneration() {
        state = LayerWindowState(id: 42, pid: 100, level: 0, subLevel: state.subLevel, processStart: 100, generation: 124)
    }
}
