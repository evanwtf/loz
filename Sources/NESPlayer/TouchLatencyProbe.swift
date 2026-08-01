import SwiftUI

#if os(iOS)
    import UIKit

    /// Measures how long a touch takes to reach the app, from the touch's own
    /// timestamp.
    ///
    /// This exists because `DragGesture.Value.time` could not be trusted. Its
    /// epoch is not the reference date, so an absolute figure was impossible;
    /// calibrating against the best sample gave a relative one, and that then
    /// produced readings alternating between 0 ms and 757 ms on a device whose
    /// renderer was demonstrably healthy — a pattern with no physical
    /// explanation, which is a sign of a broken instrument rather than a
    /// discovery.
    ///
    /// `UITouch.timestamp` has none of that ambiguity: it is documented as
    /// seconds since system startup, the same base as
    /// `ProcessInfo.systemUptime`, so subtracting the two is an absolute
    /// latency in the correct units and needs no calibration.
    ///
    /// The recogniser is attached to the window and fails itself immediately,
    /// so it observes every touch in the app without claiming, delaying, or
    /// cancelling any of them. A probe that changed the behaviour it measures
    /// would be worse than none.
    final class TouchLatencyRecogniser: UIGestureRecognizer {
        var onTouch: ((Double) -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
            if let touch = touches.first {
                let seconds = ProcessInfo.processInfo.systemUptime - touch.timestamp
                onTouch?(max(0, seconds * 1000))
            }
            // Never take part in gesture arbitration.
            state = .failed
        }
    }

    /// Installs the probe on the window hosting this view.
    struct TouchLatencyProbe: UIViewRepresentable {
        let host: EmulatorHost

        func makeUIView(context _: Context) -> ProbeView {
            let view = ProbeView()
            view.host = host
            return view
        }

        func updateUIView(_ view: ProbeView, context _: Context) {
            view.host = host
        }

        final class ProbeView: UIView {
            var host: EmulatorHost?
            private var recogniser: TouchLatencyRecogniser?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard recogniser == nil, let window else { return }

                let recogniser = TouchLatencyRecogniser()
                recogniser.onTouch = { [weak self] ms in
                    MainActor.assumeIsolated { self?.host?.noteTouchLatency(ms) }
                }
                // Leave every other recogniser and view untouched.
                recogniser.cancelsTouchesInView = false
                recogniser.delaysTouchesBegan = false
                recogniser.delaysTouchesEnded = false
                window.addGestureRecognizer(recogniser)
                self.recogniser = recogniser
            }
        }
    }
#endif
