import Foundation
import CoreGraphics

/// 区分按住拖动与单击跟随；鼠标和窗口均采用 AppKit 全局坐标。
public struct MoveGesture {
    private enum Phase { case idle, pressed, dragging, following, dropped }
    private var phase = Phase.idle
    private var pointerStart = CGPoint.zero
    private var originStart = CGPoint.zero
    public var isFollowing: Bool { phase == .following }
    public var isMoving: Bool { phase == .following || phase == .pressed || phase == .dragging }

    public init() {}

    public mutating func press(at pointer: CGPoint, windowOrigin: CGPoint) {
        if phase == .following {
            phase = .dropped
            return
        }
        pointerStart = pointer
        originStart = windowOrigin
        phase = .pressed
    }

    public mutating func drag(to pointer: CGPoint) -> CGPoint? {
        guard phase == .pressed || phase == .dragging else { return nil }
        let dx = pointer.x - pointerStart.x
        let dy = pointer.y - pointerStart.y
        if hypot(dx, dy) >= 3 { phase = .dragging }
        guard phase == .dragging else { return nil }
        return CGPoint(x: originStart.x + dx, y: originStart.y + dy)
    }

    public mutating func release() {
        switch phase {
        case .pressed: phase = .following
        case .dragging, .dropped: phase = .idle
        default: break
        }
    }

    public func follow(to pointer: CGPoint) -> CGPoint? {
        guard isFollowing else { return nil }
        return CGPoint(x: originStart.x + pointer.x - pointerStart.x,
                       y: originStart.y + pointer.y - pointerStart.y)
    }

    public mutating func cancel() -> CGPoint? {
        guard isMoving else { return nil }
        phase = .idle
        return originStart
    }

    public mutating func drop() { phase = .idle }
}
