import CoreGraphics
import NESCore

/// How the on-screen controls should arrange themselves.
public enum ControlLayout {
    case portrait(CGSize)
    /// Width available on each side of the screen, and the full height.
    case landscape(controlWidth: CGFloat, height: CGFloat)
}

/// Sizes for the on-screen control cluster.
///
/// Deliberately platform-agnostic and free of SwiftUI, so it can be tested on
/// any platform. The layout bug that motivated extracting it — the whole
/// cluster sized against the full window height while living in the leftover
/// space below the screen, pushing it off the bottom of the display — was
/// invisible to every existing test and only showed up in a screenshot.
public struct ControlMetrics: Equatable {
    public let margin: CGFloat
    public let dpadSize: CGFloat
    public let gap: CGFloat
    public let columnWidth: CGFloat
    public let buttonSize: CGFloat
    /// Space reserved below the cluster so it sits where thumbs rest.
    public let bottomInset: CGFloat
    /// Gap between the SELECT/START row and the action buttons.
    ///
    /// Generous on purpose. A thumb travelling to A passes directly under
    /// START, and the cost of the two is asymmetric: A and B are pressed
    /// constantly, while SELECT and START are pressed a handful of times a
    /// session and interrupt the game when hit by accident. Distance is worth
    /// more here than compactness.
    public let systemRowGap: CGFloat

    /// Total horizontal extent, including margins.
    public var totalWidth: CGFloat {
        margin * 2 + dpadSize + gap + columnWidth
    }

    /// Total vertical extent. The button column is the taller of the two
    /// stacks: a system row, a gap, and the action row, whose A button is
    /// raised slightly.
    public var totalHeight: CGFloat {
        let systemRowHeight = buttonSize * 1.02 * 0.34
        let actionRowHeight = buttonSize * 1.26   // includes the A button offset
        let columnHeight = systemRowHeight + systemRowGap + actionRowHeight
        return max(dpadSize, columnHeight) + bottomInset
    }

    /// Portrait: screen above, controls filling what is left below.
    ///
    /// `size` must be the space actually available to the controls, not the
    /// whole window.
    public static func portrait(in size: CGSize) -> ControlMetrics {
        let margin: CGFloat = 20
        let usable = max(size.width - margin * 2, 0)
        let dpad = min(usable * 0.44, max(size.height, 0) * 0.62)
        let gap = usable * 0.06
        let column = max(usable - dpad - gap, 0)
        let button = min(column * 0.42, dpad * 0.46)

        return ControlMetrics(
            margin: margin,
            dpadSize: dpad,
            gap: gap,
            columnWidth: column,
            buttonSize: button,
            bottomInset: max(size.height, 0) * 0.10,
            systemRowGap: button * 1.30)
    }

    /// Landscape: pad and buttons in the margins either side of the screen.
    public static func landscape(controlWidth: CGFloat, height: CGFloat) -> ControlMetrics {
        let dpad = min(max(controlWidth, 0) * 0.92, max(height, 0) * 0.62)
        let button = min(max(controlWidth, 0) * 0.40, max(height, 0) * 0.28)

        return ControlMetrics(
            margin: 0,
            dpadSize: dpad,
            gap: 0,
            columnWidth: max(controlWidth, 0),
            buttonSize: button,
            bottomInset: 0,
            // Tighter than portrait: a landscape column is short, and the
            // cluster is centred in it rather than pushed against an edge.
            systemRowGap: button * 0.80)
    }
}

/// Maps a touch on the d-pad surface to a direction.
///
/// A single tracked surface rather than four buttons: Zelda needs reliable
/// diagonals, and discrete hit targets drop inputs when a thumb slides between
/// directions, which happens constantly while dodging.
public enum DPadGeometry {
    /// Fraction of the half-width ignored around the centre, so a resting
    /// thumb selects nothing.
    public static let deadZone: CGFloat = 0.18

    /// - Parameters:
    ///   - location: touch point in the pad's own coordinate space.
    ///   - size: the pad's edge length.
    public static func direction(at location: CGPoint, in size: CGFloat) -> NESButton {
        guard size > 0 else { return [] }

        // Normalise to -1...1 around the centre.
        let dx = (location.x / size) * 2 - 1
        let dy = (location.y / size) * 2 - 1

        var result: NESButton = []
        if abs(dx) > deadZone { result.insert(dx < 0 ? .left : .right) }
        if abs(dy) > deadZone { result.insert(dy < 0 ? .up : .down) }
        return result
    }
}
