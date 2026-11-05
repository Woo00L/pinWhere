import XCTest
import CoreGraphics
@testable import PinWhereCore

final class PinWhereCoreTests: XCTestCase {
    func testOtherPinnedWindowStillCountsAsAnObstruction() {
        let target = OrderedWindow(id: 1, pid: 100, frame: CGRect(x: 0, y: 0, width: 600, height: 400), layer: 0)
        let otherPin = OrderedWindow(id: 2, pid: 200, frame: target.frame, layer: 0)
        XCTAssertTrue(PinOrderPolicy.hasOrdinaryObstruction(targetID: 1, frontToBack: [otherPin, target]))
    }

    func testMovingOversizedOriginalKeepsItsSizeAndTitleBarReachable() {
        let rect = CGRect(x: -5000, y: 3000, width: 2000, height: 1400)
        let constrained = PinGeometry.constrainOriginal(rect, to: CGRect(x: 0, y: 25, width: 1440, height: 850))
        XCTAssertEqual(constrained.size, rect.size)
        XCTAssertEqual(constrained.minX, -1920)
        XCTAssertEqual(constrained.maxY, 875)
    }
    func testDetectsOverlappingOrdinaryWindowInFront() {
        let target = OrderedWindow(id: 1, pid: 100, frame: CGRect(x: 0, y: 0, width: 600, height: 400), layer: 0)
        let covering = OrderedWindow(id: 2, pid: 200, frame: CGRect(x: 200, y: 100, width: 500, height: 300), layer: 0)
        XCTAssertTrue(PinOrderPolicy.hasOrdinaryObstruction(targetID: 1, frontToBack: [covering, target]))
        XCTAssertFalse(PinOrderPolicy.hasOrdinaryObstruction(targetID: 1, frontToBack: [target, covering]))
    }

    func testDetectsObstructionFromTheSameApplication() {
        let target = OrderedWindow(id: 1, pid: 100, frame: CGRect(x: 0, y: 0, width: 600, height: 400), layer: 0)
        let sibling = OrderedWindow(id: 3, pid: 100, frame: target.frame, layer: 0)
        XCTAssertTrue(PinOrderPolicy.hasOrdinaryObstruction(targetID: 1, frontToBack: [sibling, target]))
    }

    func testIgnoresAbsentTargetNonoverlappingWindowsAndSystemMenus() {
        let target = OrderedWindow(id: 1, pid: 100, frame: CGRect(x: 0, y: 0, width: 600, height: 400), layer: 0)
        let distant = OrderedWindow(id: 2, pid: 200, frame: CGRect(x: 800, y: 100, width: 200, height: 300), layer: 0)
        let menu = OrderedWindow(id: 3, pid: 200, frame: target.frame, layer: 20)
        XCTAssertFalse(PinOrderPolicy.hasOrdinaryObstruction(targetID: 1, frontToBack: [distant, menu, target]))
        XCTAssertFalse(PinOrderPolicy.hasOrdinaryObstruction(targetID: 1, frontToBack: [distant, menu]))
    }
    func testConvertsWindowOnDisplayAbovePrimaryWithoutUsingMainScreen() {
        let result = PinGeometry.appKitRect(CGRect(x: -800, y: -900, width: 600, height: 400), primaryScreenHeight: 1080)
        XCTAssertEqual(result, CGRect(x: -800, y: 1580, width: 600, height: 400))
    }

    func testClickStartsFollowingAndSecondPressDropsWithoutJump() {
        var gesture = MoveGesture()
        gesture.press(at: CGPoint(x: 150, y: 250), windowOrigin: CGPoint(x: 100, y: 100))
        gesture.release()
        XCTAssertTrue(gesture.isFollowing)
        XCTAssertEqual(gesture.follow(to: CGPoint(x: 300, y: 500)), CGPoint(x: 250, y: 350))
        gesture.press(at: CGPoint(x: 300, y: 500), windowOrigin: CGPoint(x: 250, y: 350))
        gesture.release()
        XCTAssertFalse(gesture.isFollowing)
        XCTAssertNil(gesture.follow(to: CGPoint(x: 500, y: 500)))
    }

    func testDragReleaseDoesNotStartClickFollowing() {
        var gesture = MoveGesture()
        gesture.press(at: CGPoint(x: 150, y: 250), windowOrigin: CGPoint(x: 100, y: 100))
        XCTAssertEqual(gesture.drag(to: CGPoint(x: 180, y: 210)), CGPoint(x: 130, y: 60))
        gesture.release()
        XCTAssertFalse(gesture.isFollowing)
    }

    func testEscapeRestoresOriginalPositionAfterFollowing() {
        var gesture = MoveGesture()
        gesture.press(at: CGPoint(x: -1000, y: 500), windowOrigin: CGPoint(x: -1100, y: 200))
        gesture.release()
        _ = gesture.follow(to: CGPoint(x: 100, y: 500))
        XCTAssertEqual(gesture.cancel(), CGPoint(x: -1100, y: 200))
        XCTAssertFalse(gesture.isFollowing)
    }
}
