import Foundation
import CoreGraphics

public enum PinGeometry {
    /// 移动第三方窗口时只约束标题栏可达，绝不改变原窗口尺寸。
    public static func constrainOriginal(_ rect: CGRect, to screen: CGRect) -> CGRect {
        CGRect(x: min(max(rect.minX, screen.minX - rect.width + 80), screen.maxX - 80),
               y: min(max(rect.minY, screen.minY - rect.height + 60), screen.maxY - rect.height),
               width: rect.width, height: rect.height)
    }

    public static func appKitRect(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

}
