#if os(iOS)

    import UIKit

    /// Touch feedback for the on-screen pad.
    ///
    /// Two reasons this is a type rather than a call site detail:
    ///
    /// Generators are kept alive and pre-armed. `UIImpactFeedbackGenerator`
    /// warms the Taptic Engine on `prepare()`; allocating one per press means
    /// every press pays that warm-up, which lands the tap late enough to feel
    /// disconnected from the button that caused it. For a game where a sword
    /// swing is a single frame, late feedback is worse than none.
    ///
    /// The intensities are calibrated relative to each other. The d-pad fires
    /// far more often than anything else, so it is the softest — but it was
    /// previously set to 0.3 of a `.rigid` impact, which is below the threshold
    /// most people can feel at all, and read as "the d-pad has no haptics".
    @MainActor
    enum Haptics {
        private static let light: UIImpactFeedbackGenerator = {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            return generator
        }()

        private static let soft: UIImpactFeedbackGenerator = {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            return generator
        }()

        /// A face button — the most deliberate press, so the firmest tap.
        static func action() {
            light.impactOccurred()
            light.prepare()
        }

        /// A direction change. Softer than a face button because holding a
        /// direction and sliding around the pad fires this constantly, but
        /// still firmly enough to feel through a case.
        static func direction() {
            soft.impactOccurred(intensity: 0.7)
            soft.prepare()
        }

        /// Start and Select. Infrequent, and worth confirming clearly, because
        /// they are the presses whose effect is least visible on screen.
        static func system() {
            light.impactOccurred(intensity: 0.9)
            light.prepare()
        }
    }

#endif
