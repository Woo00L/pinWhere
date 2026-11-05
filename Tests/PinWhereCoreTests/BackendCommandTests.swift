import XCTest
@testable import PinWhereCore

final class BackendCommandTests: XCTestCase {
    func testArgumentsStayLiteralAndOutputIsComplete() async throws {
        let data = try await BackendCommand.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                                arguments: ["%s", "$(whoami) `echo bad` ; 中文"])
        XCTAssertEqual(String(data: data, encoding: .utf8), "$(whoami) `echo bad` ; 中文")
    }
    func testOutputLargerThanPipeCapacityDoesNotDeadlock() async throws {
        let data = try await BackendCommand.run(executable: URL(fileURLWithPath: "/usr/bin/head"),
                                                arguments: ["-c", "200000", "/dev/zero"])
        XCTAssertEqual(data.count, 200000)
    }
    func testUnresponsiveBackendIsTerminated() async throws {
        let start = Date()
        do {
            _ = try await BackendCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
            XCTFail("超时后必须拒绝确认")
        } catch { XCTAssertEqual(error as? WindowLayerError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
