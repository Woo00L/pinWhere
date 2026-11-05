import Foundation
import CoreGraphics

public struct OrderedWindow {
    public let id: UInt32
    public let pid: Int32
    public let frame: CGRect
    public let layer: Int

    public init(id: UInt32, pid: Int32, frame: CGRect, layer: Int) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.layer = layer
    }
}

/// 只读检测普通窗口的实际遮挡，不发出抬高或激活请求。
public enum PinOrderPolicy {
    /// 其他置顶窗口也可能造成真实遮挡；系统菜单等更高层级不计入普通窗口。
    public static func hasOrdinaryObstruction(targetID: UInt32, frontToBack: [OrderedWindow]) -> Bool {
        guard let index = frontToBack.firstIndex(where: { $0.id == targetID }) else { return false }
        let target = frontToBack[index]
        return frontToBack[..<index].contains {
            $0.layer == 0 && $0.frame.intersection(target.frame).width > 1 &&
            $0.frame.intersection(target.frame).height > 1 && !$0.frame.intersection(target.frame).isNull
        }
    }
}
