import XCTest
import AppKit
@testable import PinWhereCore

final class SetupPolicyTests: XCTestCase {
    private func context(_ change: (inout SetupContext) -> Void = { _ in }) -> SetupContext {
        var context = SetupContext(probe: BackendSetupProbe(schema: 1, sipCompatible: true,
            nvramProtectionDisabled: true, bootArgumentEnabled: true, bootArgumentConfigured: true,
            accessibilityGranted: true, extensionInstalled: true, extensionReady: true),
            installedInApplications: true, appPermission: true, separateSpaces: true,
            backendConnected: false, conflictingBackend: false)
        change(&context)
        return context
    }

    func testReadyConditionsStartOnlyMissingBackend() {
        XCTAssertEqual(context().nextStep, .startBackend)
        XCTAssertTrue(context().mayStartBackend)
        let connected = context { $0.backendConnected = true }
        XCTAssertEqual(connected.nextStep, .ready)
        XCTAssertFalse(connected.mayStartBackend)
    }

    func testMissingExtensionNeverAutomaticallyRequestsAdministrator() {
        let setup = context { $0.probe.extensionReady = false }
        XCTAssertEqual(setup.nextStep, .loadExtension)
        XCTAssertFalse(setup.mayStartBackend)
        XCTAssertTrue(setup.mayLoadExtension)
    }

    func testBlockedSystemCannotLoadOrStartAnything() {
        let cases: [(SetupContext, SetupStep)] = [
            (context { $0.installedInApplications = false }, .installApp),
            (context { $0.probe.sipCompatible = false }, .systemSecurity),
            (context { $0.probe.bootArgumentEnabled = false }, .bootArgument),
            (context { $0.appPermission = false }, .appPermission),
            (context { $0.probe.accessibilityGranted = false }, .backendPermission),
            (context { $0.separateSpaces = false }, .separateSpaces),
            (context { $0.conflictingBackend = true }, .backendConflict)
        ]
        for (setup, step) in cases {
            XCTAssertEqual(setup.nextStep, step)
            XCTAssertFalse(setup.mayStartBackend)
            XCTAssertFalse(setup.mayLoadExtension)
        }
    }

    func testExistingDaemonCannotHideMissingPermissionOrExtension() {
        XCTAssertEqual(context { $0.backendConnected = true; $0.appPermission = false }.nextStep, .appPermission)
        XCTAssertEqual(context { $0.backendConnected = true; $0.probe.extensionReady = false }.nextStep, .loadExtension)
    }

    func testUnknownProbeSchemaFailsClosed() throws {
        let data = Data(#"{"schema":2,"sipCompatible":true,"nvramProtectionDisabled":true,"bootArgumentEnabled":true,"bootArgumentConfigured":true,"accessibilityGranted":true,"extensionInstalled":true,"extensionReady":true}"#.utf8)
        XCTAssertThrowsError(try BackendSetupProbe.decode(data))
    }

    func testAdministratorCommandKeepsPathsLiteral() {
        let path = "/Applications/Pin Where ' $(touch /tmp/should-not-exist).app/Contents/Helpers/yabai"
        let script = SetupAdministratorCommand.script(executable: path, operation: .loadExtension, uid: 501)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("SUDO_UID=501"))
        XCTAssertTrue(script.contains("--pinwhere-load-extension"))
        // 单引号必须拆开并转义，不能把用户可控路径作为 shell 语句执行。
        XCTAssertTrue(script.contains("'\\\"'\\\"'"))
        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        XCTAssertEqual(appleScript?.compileAndReturnError(&error), true, "\(String(describing: error))")
    }

    func testMigrationAcceptsOnlyAnEmptyRecoveryArray() {
        XCTAssertTrue(SetupMigrationPolicy.mayStopBackend(journal: nil))
        XCTAssertTrue(SetupMigrationPolicy.mayStopBackend(journal: Data(" [ ] \n".utf8)))
        for value in ["{}", "null", "garbage", "[{\"id\": 5}]"] {
            XCTAssertFalse(SetupMigrationPolicy.mayStopBackend(journal: Data(value.utf8)))
        }
    }

    func testMigrationNeverTreatsUserYabaiAsBundledPinWhere() {
        XCTAssertTrue(SetupMigrationPolicy.isPreviousBackend(path: "/old/PinWhere.app/Contents/Helpers/yabai", bundleIdentifier: "cn.pinwhere.app"))
        XCTAssertFalse(SetupMigrationPolicy.isPreviousBackend(path: "/opt/homebrew/bin/yabai", bundleIdentifier: "cn.pinwhere.app"))
        XCTAssertFalse(SetupMigrationPolicy.isPreviousBackend(path: "/old/Other.app/Contents/Helpers/yabai", bundleIdentifier: "other.app"))
    }
}
