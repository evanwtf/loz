import Foundation
import QuartzCore

/// Turns a gesture event's timestamp into a delivery delay.
///
/// `DragGesture.Value.time` is a `Date`, but not one measured from the
/// reference date: subtracting it from `Date()` on a device produces a
/// difference of roughly 807 million seconds — about twenty-five years, i.e.
/// the whole span since 2001. Its epoch is simply something else.
///
/// This went unnoticed for longer than it should have because the first
/// consumer guarded against absurd readings and dropped every sample, so the
/// overlay reported a permanent "0 ms" that was indistinguishable from perfect
/// delivery. The tap test, which printed the raw figure instead of hiding it,
/// exposed it immediately. A sanity check that silently discards its input is
/// worse than no check.
///
/// What the timestamp *does* do is advance in real time. So the difference
/// between it and now is a fixed unknown offset plus the delay being measured,
/// and calibrating against the smallest difference ever seen cancels the
/// offset. The result is delay *in excess of the best delivery observed* —
/// which is the useful quantity anyway, since a stall shows up as excess and a
/// constant baseline does not.
@MainActor
public enum InputClock {
    private static var best = Double.infinity

    /// Delivery delay in milliseconds, relative to the fastest sample so far.
    public static func delayMS(since eventTime: Date) -> Double {
        let raw = CFAbsoluteTimeGetCurrent() - eventTime.timeIntervalSinceReferenceDate
        best = min(best, raw)
        return max(0, (raw - best) * 1000)
    }

    /// Forgets the calibration. Worth doing at the start of a measured run so
    /// one early outlier cannot flatter everything after it.
    public static func recalibrate() {
        best = .infinity
    }
}
