import SwiftUI
import NESCore

/// Keyboard input for macOS and hardware keyboards on iPad.
///
/// Uses SwiftUI's `onKeyPress`, which reports both down and up phases, so a
/// held direction stays held — essential for a game where you walk by holding
/// a direction rather than tapping it.
struct KeyboardControls: ViewModifier {
    let host: EmulatorHost
    @Binding var showDiagnostics: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
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
        case .upArrow:    return .up
        case .downArrow:  return .down
        case .leftArrow:  return .left
        case .rightArrow: return .right
        case .return:     return .start
        case .space:      return .select
        case "z":         return .b
        case "x":         return .a
        default:          return nil
        }
    }
}
