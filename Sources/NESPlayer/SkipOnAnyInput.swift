import GameController
import SwiftUI

/// Dismisses a waiting screen on *any* input: a tap, a key, or any button on
/// any attached controller.
///
/// "Any" is the requirement rather than a nicety. This sits in front of the
/// game on three platforms whose only shared input is "the player did
/// something", and a skip control that has to be found is worse than no skip
/// control — on an Apple TV there is no pointer to find it with.
///
/// The controller half deliberately uses the gamepad's `valueChangedHandler`
/// rather than per-button handlers, because the question is not *which* button.
/// It is cleared when the screen goes away so it cannot outlive it: the handler
/// coexists with the per-button ones `GameControllerSupport` installs for play,
/// so leaving it attached would keep firing a skip into a screen that no longer
/// exists.
struct SkipOnAnyInput: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            // Without a shape the gesture only lands on drawn pixels, which on
            // a mostly-empty screen means most taps miss.
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .focusable()
            .onKeyPress { _ in
                action()
                return .handled
            }
            .task {
                defer { detachAll() }
                await watchControllers()
            }
    }

    private func watchControllers() async {
        for controller in GCController.controllers() { attach(controller) }
        let connections = NotificationCenter.default.notifications(
            named: .GCControllerDidConnect)
        for await note in connections {
            if let controller = note.object as? GCController { attach(controller) }
        }
    }

    private func attach(_ controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = { _, element in
            guard let button = element as? GCControllerButtonInput, button.isPressed
            else { return }
            Task { @MainActor in action() }
        }
    }

    private func detachAll() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
    }
}

extension View {
    func skipOnAnyInput(perform action: @escaping () -> Void) -> some View {
        modifier(SkipOnAnyInput(action: action))
    }
}
