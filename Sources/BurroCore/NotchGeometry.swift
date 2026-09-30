// Pure screen geometry places the panel flush with the physical top edge, reserving the camera housing when present.
import Foundation
import CoreGraphics

public struct NotchGeometry: Sendable {
    public var frame: CGRect
    public var headerHeight: CGFloat
    public var hardwareGap: CGFloat
    public var hasHardwareNotch: Bool
    public static func layout(screen: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                              hardwareWidth: CGFloat, expanded: Bool, visibleAgents: Int = 3) -> Self {
        // A safe inset is evidence of a camera even if auxiliary rectangles are temporarily unavailable.
        let hasNotch = safeTop > 0
        let gap = hasNotch ? (hardwareWidth > 0 ? hardwareWidth : 210) + 12 : 0
        let header: CGFloat = hasNotch ? max(32, safeTop) + (expanded ? 5 : 2) : (expanded ? 36 : 26)
        let compactWidth = hasNotch ? gap + 144 : 156
        let width = min(expanded ? max(480, compactWidth) : compactWidth, max(1, screen.width - 24))
        let bodyHeight: CGFloat = visibleAgents == 0 ? 148 : 78 + CGFloat(min(visibleAgents, 5)) * 56
        let desiredHeight = expanded ? header + bodyHeight : header
        let top = screen.maxY
        let height = min(desiredHeight, max(1, top - visibleFrame.minY - 12))
        return .init(frame: CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height),
                     headerHeight: header, hardwareGap: gap, hasHardwareNotch: hasNotch)
    }
}
