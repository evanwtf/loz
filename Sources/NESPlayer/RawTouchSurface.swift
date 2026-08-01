import SwiftUI

#if os(iOS)
    import UIKit

    /// A touch surface that reports presses from `touchesBegan` directly,
    /// bypassing SwiftUI's gesture system.
    ///
    /// `DragGesture(minimumDistance: 0)` is documented to fire on touch-down
    /// and mostly does — but not reliably here. Measurement put raw delivery at
    /// 13 ms while the gesture handler ran hundreds of milliseconds later, and
    /// the behaviour matched exactly: a d-pad direction had to be held for over
    /// a second before Link took a step. A gesture recogniser has to win
    /// arbitration against every other recogniser in the hierarchy before its
    /// handler runs, and that negotiation is not free.
    ///
    /// `touchesBegan` has no such negotiation. The view is the first responder
    /// for the touch and hears about it immediately, which is the whole reason
    /// games are told to use it.
    ///
    /// Reports a location on down and on move, and `nil` on end or cancel, so
    /// one callback covers the d-pad's slide-between-directions case as well as
    /// a simple button.
    struct RawTouchSurface: UIViewRepresentable {
        /// Touch position in the view's own coordinates, or `nil` when it ends.
        let onTouch: (CGPoint?) -> Void

        func makeUIView(context _: Context) -> TouchView {
            let view = TouchView()
            view.onTouch = onTouch
            view.isMultipleTouchEnabled = false
            view.backgroundColor = .clear
            return view
        }

        func updateUIView(_ view: TouchView, context _: Context) {
            view.onTouch = onTouch
        }

        final class TouchView: UIView {
            var onTouch: ((CGPoint?) -> Void)?

            override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent?) {
                report(touches)
            }

            override func touchesMoved(_ touches: Set<UITouch>, with _: UIEvent?) {
                report(touches)
            }

            override func touchesEnded(_: Set<UITouch>, with _: UIEvent?) {
                onTouch?(nil)
            }

            /// Cancellation matters as much as ending: a touch the system takes
            /// away — for a call, or an edge gesture — must release the button,
            /// or the game is left holding a direction nobody is pressing.
            override func touchesCancelled(_: Set<UITouch>, with _: UIEvent?) {
                onTouch?(nil)
            }

            private func report(_ touches: Set<UITouch>) {
                guard let touch = touches.first else { return }
                onTouch?(touch.location(in: self))
            }
        }
    }
#endif
