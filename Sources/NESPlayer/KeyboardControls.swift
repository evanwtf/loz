import NESCore
import SwiftUI

/// Keyboard input for macOS and hardware keyboards on iOS and iPad.
///
/// Uses SwiftUI's `onKeyPress`, which reports both down and up phases, so a
/// held direction stays held — essential for a game where you walk by holding
/// a direction rather than tapping it.
struct KeyboardControls: ViewModifier {
    let host: EmulatorHost
    @Binding var showDiagnostics: Bool

    /// `onKeyPress` only fires on a view that actually holds focus, and
    /// `.focusable()` merely makes it eligible for focus. On macOS that was
    /// enough because the window makes the hosting view first responder at
    /// launch; on iOS nothing ever did, so no key ever reached the app and the
    /// whole modifier was silently dead. Claiming focus explicitly is what
    /// makes a hardware keyboard work on both.
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(phases: [.down, .up]) { press in
                handle(press) ? .handled : .ignored
            }
    }

    private func handle(_ press: KeyPress) -> Bool {
        let pressed = press.phase == .down

        if let button = Self.button(for: press.key) {
            host.setButton(button, pressed: pressed)
            return true
        }

        // Non-gameplay keys act on key-down only.
        guard pressed else { return false }
        switch press.characters.lowercased() {
        case "p":
            host.isPaused.toggle()
            return true
        case "r":
            host.reset()
            return true
        case "d":
            showDiagnostics.toggle()
            return true
        case "f":
            host.speedMultiplier = host.speedMultiplier == 1 ? 4 : 1
            return true
        default:
            return false
        }
    }

    private static func button(for key: KeyEquivalent) -> NESButton? {
        switch key {
        case .upArrow:    .up
        case .downArrow:  .down
        case .leftArrow:  .left
        case .rightArrow: .right
        case .return:     .start
        case .space:      .select
        case "z":         .b
        case "x":         .a
        default:          nil
        }
    }
}
