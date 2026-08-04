#if os(tvOS)
    import GameController
    import SwiftUI
    import UIKit

    /// Claims controller input for the app instead of the system.
    ///
    /// Without this, tvOS keeps the controller for itself and the app only sees
    /// what is left over. Three separate symptoms came from that one fact:
    ///
    /// - **Circle exited the game.** The system reads B/Circle as "back" and
    ///   leaves the app, so the button Zelda uses for the sword quit instead.
    /// - **The menu could not be navigated.** Setting
    ///   `dpad.valueChangedHandler` stops the system synthesising focus
    ///   movement, so the menu opened with its close button focused and focus
    ///   could not be moved off it.
    /// - **Detaching the handlers did not give focus back**, because the
    ///   routing decision outlives the handler.
    ///
    /// `controllerUserInteractionEnabled = false` says the app handles the
    /// controller, all of it. The consequence is that nothing is navigated for
    /// us any more — the menu has to move its own selection, which
    /// `MenuRouter` does.
    ///
    /// The player can always still leave: the TV/Home button is reserved by the
    /// system and this cannot take it.
    struct ControllerInputCapture: UIViewControllerRepresentable {
        func makeUIViewController(context _: Context) -> GCEventViewController {
            let controller = GCEventViewController()
            controller.controllerUserInteractionEnabled = false
            // Purely a claim on controller events; it must never take a touch
            // or a layout slot from the game.
            controller.view.isUserInteractionEnabled = false
            controller.view.backgroundColor = .clear
            return controller
        }

        func updateUIViewController(_ controller: GCEventViewController, context _: Context) {
            // Reasserted on every update: the value resets if the view
            // controller is re-established, and losing it silently returns
            // every symptom above.
            controller.controllerUserInteractionEnabled = false
        }
    }
#endif
