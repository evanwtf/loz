import Foundation

/// Where a frame's time went, refreshed every 120 frames.
///
/// Published as well as logged because pulling the unified log off a physical
/// device needs root, which makes the log useless in the exact situation it was
/// added for — someone holding the phone, reproducing the bug. On screen the
/// numbers are simply there.
public struct FrameProfile: Equatable {
    public var emulateMS: Double = 0
    public var renderMS: Double = 0
    /// Mean spacing between ticks. Should sit at 16.67 ms.
    public var gapMS: Double = 0
    public var worstGapMS: Double = 0
    /// Ticks in the last sample that missed a 60 Hz refresh.
    public var lateTicks: Int = 0

    public init() {}
}

/// How long a touch took to reach the app.
///
/// `DragGesture.Value.time` is the timestamp of the *event*, not of the handler
/// run. Subtracting it from now therefore measures everything between the
/// finger landing and the handler running: UIKit's delivery, the run loop's
/// availability, and SwiftUI's gesture recognition. That is precisely the
/// window "the button took half a second" lives in, and no timer inside the
/// frame loop can see it — which is why several rounds of reasoning about the
/// frame loop got nowhere.
///
/// `samples` matters as much as the timings: without it, "0 ms" and "no event
/// ever arrived" are indistinguishable, and those are opposite diagnoses.
public struct InputLatency: Equatable {
    public var lastMS: Double = 0
    public var worstMS: Double = 0
    public var samples: Int = 0

    public init() {}

    public init(lastMS: Double, worstMS: Double, samples: Int) {
        self.lastMS = lastMS
        self.worstMS = worstMS
        self.samples = samples
    }
}

/// Diagnostic counters, kept off the host so that watching them does not
/// invalidate anything but the readout.
///
/// The separation is not tidiness. Anything observing an `ObservableObject` is
/// rebuilt when any of its published properties changes, so counters that tick
/// at frame rate — or, worse, at touch-event rate — drag every sibling view
/// into a rebuild with them. That is what made the on-screen controls
/// unresponsive: the gesture recognisers were being replaced faster than a
/// touch could be recognised.
@MainActor
public final class DiagnosticsStream: ObservableObject {
    @Published public internal(set) var framesPerSecond: Double = 0
    @Published public internal(set) var profile = FrameProfile()
    @Published public internal(set) var inputLatency = InputLatency()
    @Published public internal(set) var presentation = Presentation()

    public init() {}
}

/// How much of what the emulator draws actually reaches the screen.
///
/// The number that was missing. Everything else measured work the app *did*;
/// this measures what the player *saw*, and the two came apart completely — a
/// screen recording showed the picture unchanged for twenty seconds while the
/// frame clock reported a steady 60 fps throughout.
///
/// It is also the only input measurement that does not arrive too late to be
/// useful. A callout or a latency sample can only be recorded once the press
/// has finally landed, so neither can show the delay preceding it. This runs
/// continuously and needs no press at all: `shownPerSecond` far below the
/// emulated rate *is* the lag, whether or not anyone is touching the screen.
public struct Presentation: Equatable {
    /// Frames per second that actually reached the display.
    public var shownPerSecond: Double = 0
    /// Age of the picture currently on screen.
    public var staleMS: Double = 0
    public var worstStaleMS: Double = 0

    public init() {}
}
