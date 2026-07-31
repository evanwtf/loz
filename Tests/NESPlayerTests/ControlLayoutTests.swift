import CoreGraphics
import NESCore
@testable import NESPlayer
import Testing

/// Guards the on-screen control layout.
///
/// These exist because of a real regression: adding landscape support made the
/// portrait cluster size itself against the *full window* height while living
/// in the leftover space below the screen. It was pushed off the bottom of the
/// display, so the game appeared to have no controls at all — and every test
/// passed, because none of them looked at layout.
@Suite("On-screen control layout")
struct ControlLayoutTests {
    /// Real device sizes in points, portrait. The controls occupy what is left
    /// after a 4:3 screen at full width, which is what these heights model.
    static let portraitCases: [(name: String, size: CGSize)] = [
        ("iPhone SE", CGSize(width: 320, height: 328)),
        ("iPhone 13 mini", CGSize(width: 375, height: 531)),
        ("iPhone 17", CGSize(width: 393, height: 557)),
        ("iPhone 17 Pro Max", CGSize(width: 440, height: 626)),
        ("iPad mini", CGSize(width: 744, height: 574)),
        ("iPad Pro 13", CGSize(width: 1024, height: 598)),
    ]

    // MARK: Fitting

    @Test("Portrait controls fit the available width on every device")
    func portraitFitsWidth() {
        for device in Self.portraitCases {
            let metrics = ControlMetrics.portrait(in: device.size)
            #expect(
                metrics.totalWidth <= device.size.width + 0.5,
                "\(device.name): cluster \(metrics.totalWidth)pt wide in \(device.size.width)pt")
        }
    }

    /// The exact failure mode that shipped: a cluster taller than the space it
    /// is given renders off-screen.
    @Test("Portrait controls fit the available height on every device")
    func portraitFitsHeight() {
        for device in Self.portraitCases {
            let metrics = ControlMetrics.portrait(in: device.size)
            #expect(
                metrics.totalHeight <= device.size.height + 0.5,
                "\(device.name): cluster \(metrics.totalHeight)pt tall in \(device.size.height)pt")
        }
    }

    /// Documents what these tests do and do not cover.
    ///
    /// The regression was *not* bad math — the metrics fit comfortably either
    /// way. It was the view framing itself to the full window height (852pt)
    /// while occupying only the leftover space (557pt) and bottom-aligning,
    /// which pushed the cluster below the visible area.
    ///
    /// That is a view-composition fault, not a geometry one, and no
    /// pure-function test can reach it. It is prevented structurally instead:
    /// `TouchControls` measures with its own `GeometryReader` rather than
    /// trusting a size passed down. What this asserts is the weaker but real
    /// property that makes local measurement safe — bottom inset scales with
    /// the space given, so measuring the wrong box misplaces the cluster.
    @Test("Bottom inset tracks the measured height, so the wrong box misplaces it")
    func insetTracksMeasuredHeight() {
        let window = CGSize(width: 393, height: 852)
        let available = CGSize(width: 393, height: 557)

        let correct = ControlMetrics.portrait(in: available)
        let wrong = ControlMetrics.portrait(in: window)

        #expect(correct.totalHeight <= available.height)
        #expect(
            wrong.bottomInset > correct.bottomInset,
            "inset must depend on the measured height for local measurement to matter")
    }

    @Test("Landscape controls fit their side margin")
    func landscapeFitsMargin() {
        // Screen takes 62% of width; the rest is split between the two sides.
        let cases: [CGSize] = [
            CGSize(width: 852, height: 393),
            CGSize(width: 956, height: 440),
            CGSize(width: 1133, height: 744),
        ]
        for size in cases {
            let screenWidth = min(size.height * (4.0 / 3.0), size.width * 0.62)
            let controlWidth = (size.width - screenWidth) / 2
            let metrics = ControlMetrics.landscape(
                controlWidth: controlWidth, height: size.height)

            #expect(metrics.dpadSize <= controlWidth + 0.5)
            #expect(metrics.dpadSize <= size.height + 0.5)
            #expect(metrics.buttonSize > 0)
        }
    }

    // MARK: Sanity

    @Test("Every dimension is positive and usable")
    func dimensionsAreUsable() {
        for device in Self.portraitCases {
            let metrics = ControlMetrics.portrait(in: device.size)
            #expect(metrics.dpadSize > 40, "\(device.name): d-pad too small to hit")
            #expect(metrics.buttonSize > 20, "\(device.name): buttons too small to hit")
            #expect(metrics.columnWidth > 0)
            #expect(metrics.gap >= 0)
        }
    }

    @Test("Degenerate sizes produce no negative dimensions")
    func degenerateSizes() {
        for size in [CGSize.zero, CGSize(width: 10, height: 10), CGSize(width: -5, height: -5)] {
            let metrics = ControlMetrics.portrait(in: size)
            #expect(metrics.dpadSize >= 0)
            #expect(metrics.columnWidth >= 0)
            #expect(metrics.buttonSize >= 0)
            #expect(metrics.totalWidth >= 0)
        }
    }

    @Test("Controls scale with the space available")
    func scalesWithSpace() {
        let small = ControlMetrics.portrait(in: CGSize(width: 320, height: 328))
        let large = ControlMetrics.portrait(in: CGSize(width: 440, height: 626))
        #expect(large.dpadSize > small.dpadSize)
        #expect(large.buttonSize > small.buttonSize)
    }

    // MARK: D-pad direction mapping

    @Test("The centre of the d-pad selects no direction")
    func deadZoneAtCentre() {
        let size: CGFloat = 200
        let centre = CGPoint(x: 100, y: 100)
        #expect(DPadGeometry.direction(at: centre, in: size).isEmpty)
    }

    @Test("Cardinal touches select one direction each")
    func cardinalDirections() {
        let size: CGFloat = 200
        let cases: [(CGPoint, NESButton, String)] = [
            (CGPoint(x: 100, y: 10), .up, "top"),
            (CGPoint(x: 100, y: 190), .down, "bottom"),
            (CGPoint(x: 10, y: 100), .left, "left"),
            (CGPoint(x: 190, y: 100), .right, "right"),
        ]
        for (point, expected, name) in cases {
            let result = DPadGeometry.direction(at: point, in: size)
            #expect(result == expected, "\(name) gave \(result.rawValue)")
        }
    }

    /// Diagonals are the reason this is one surface and not four buttons —
    /// Zelda is unplayable without them.
    @Test("Corner touches select diagonals")
    func diagonals() {
        let size: CGFloat = 200
        let cases: [(CGPoint, NESButton, String)] = [
            (CGPoint(x: 20, y: 20), [.up, .left], "top-left"),
            (CGPoint(x: 180, y: 20), [.up, .right], "top-right"),
            (CGPoint(x: 20, y: 180), [.down, .left], "bottom-left"),
            (CGPoint(x: 180, y: 180), [.down, .right], "bottom-right"),
        ]
        for (point, expected, name) in cases {
            let result = DPadGeometry.direction(at: point, in: size)
            #expect(result == expected, "\(name) gave \(result.rawValue)")
        }
    }

    @Test("The dead zone boundary behaves as specified")
    func deadZoneBoundary() {
        let size: CGFloat = 200
        let half = size / 2
        // Just inside the dead zone on the x axis: no horizontal direction.
        let inside = CGPoint(x: half + half * (DPadGeometry.deadZone - 0.02), y: half)
        #expect(!DPadGeometry.direction(at: inside, in: size).contains(.right))

        // Just outside: right is selected.
        let outside = CGPoint(x: half + half * (DPadGeometry.deadZone + 0.05), y: half)
        #expect(DPadGeometry.direction(at: outside, in: size).contains(.right))
    }

    @Test("Opposite directions are never selected together")
    func noOpposites() {
        let size: CGFloat = 200
        for x in stride(from: CGFloat(0), through: 200, by: 7) {
            for y in stride(from: CGFloat(0), through: 200, by: 7) {
                let result = DPadGeometry.direction(at: CGPoint(x: x, y: y), in: size)
                #expect(!(result.contains(.left) && result.contains(.right)))
                #expect(!(result.contains(.up) && result.contains(.down)))
            }
        }
    }

    @Test("A zero-sized pad selects nothing rather than crashing")
    func zeroSizedPad() {
        #expect(DPadGeometry.direction(at: CGPoint(x: 5, y: 5), in: 0).isEmpty)
    }
}
