import Foundation

/// Routes controller input to the in-game menu while it is open.
///
/// The menu cannot be navigated by tvOS's focus engine. Once an app sets
/// `dpad.valueChangedHandler`, the system stops synthesising focus movement
/// from that controller and hands the raw input to the app — so the menu
/// appeared with its close button focused and focus could not be moved off it.
/// Detaching the handlers did not give it back either: the routing decision
/// outlives the handler.
///
/// So the app navigates its own menu. That is more code than leaning on focus,
/// and it is the only thing that works while the game also wants the pad.
///
/// A reference type because the controller handlers are closures captured once
/// when a controller attaches; they cannot see later values of a view's state.
@MainActor
final class MenuRouter {
    /// Whether the menu currently owns the pad.
    var isOpen = false

    var move: (Int) -> Void = { _ in }
    var activate: () -> Void = {}
    var close: () -> Void = {}

    /// Last vertical direction reported, so a held stick moves the selection
    /// once rather than sixty times a second.
    private var lastVertical = 0

    /// Converts a continuous axis into single steps.
    func steer(vertical: Float) {
        let direction = vertical > 0.5 ? -1 : (vertical < -0.5 ? 1 : 0)
        guard direction != lastVertical else { return }
        lastVertical = direction
        if direction != 0 { move(direction) }
    }

    /// Forgets the held direction, so reopening the menu does not swallow the
    /// first press.
    func resetSteering() { lastVertical = 0 }
}
