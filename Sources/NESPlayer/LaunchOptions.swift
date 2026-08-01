import Foundation
import NESCore

#if os(iOS)
    import UIKit
#endif

/// Launch-time overrides, read from the standard argument domain so they can be
/// passed as `-key value` on launch:
///
/// ```sh
/// xcrun simctl launch "iPhone 17" wtf.evan.loz.zelda -nesOrientation landscape
/// ```
///
/// These exist so automated runs can verify both orientations without a human
/// physically rotating a device — the simulator cannot be rotated from the
/// command line, but the app can rotate itself.
public enum LaunchOptions {
    /// `portrait` or `landscape`, if the caller pinned one.
    public static var requestedOrientation: String? {
        UserDefaults.standard.string(forKey: "nesOrientation")?.lowercased()
    }

    /// Starts with the diagnostics overlay visible. On by default.
    ///
    /// This is a development build of an emulator, not a shipping game, and
    /// the overlay is the only way to answer "did that press register, and how
    /// late?" while holding the device. Defaulting it off meant every
    /// investigation began by asking someone to go and turn it on. Pass
    /// `-nesDiagnostics 0` for a clean screenshot.
    public static var showDiagnostics: Bool {
        (UserDefaults.standard.object(forKey: "nesDiagnostics") as? Bool) ?? true
    }

    /// Starts muted — useful when capturing screenshots in bulk.
    public static var startMuted: Bool {
        UserDefaults.standard.bool(forKey: "nesMuted")
    }

    /// Buttons to draw as held, e.g. `-nesHoldButtons up,a`.
    ///
    /// Screenshot support only. A simulator cannot hold a touch, so the press
    /// callouts are otherwise uncapturable and would go to a device unverified
    /// — which is exactly how the control cluster once shipped off-screen.
    ///
    /// This seeds the *visual* state and nothing else. It deliberately does not
    /// reach `setButton`: a screenshot run must not feed phantom input to the
    /// game.
    public static var forcedHeldButtons: NESButton {
        guard let raw = UserDefaults.standard.string(forKey: "nesHoldButtons")
        else { return [] }

        let names: [String: NESButton] = [
            "up": .up, "down": .down, "left": .left, "right": .right,
            "select": .select, "start": .start, "a": .a, "b": .b,
        ]
        return raw.lowercased()
            .split(separator: ",")
            .compactMap { names[$0.trimmingCharacters(in: .whitespaces)] }
            .reduce(into: NESButton()) { $0.formUnion($1) }
    }

    /// Opens the in-game menu at launch, so its layout can be captured without
    /// a synthetic tap.
    public static var openMenu: Bool {
        UserDefaults.standard.bool(forKey: "nesMenu")
    }

    #if os(iOS)
        /// Asks the window scene to adopt the requested orientation, if any.
        @MainActor
        public static func applyRequestedOrientation() {
            guard let requested = requestedOrientation else { return }

            let mask: UIInterfaceOrientationMask
            switch requested {
            case "landscape", "landscaperight": mask = .landscapeRight
            case "landscapeleft":               mask = .landscapeLeft
            case "portrait":                    mask = .portrait
            default:                            return
            }

            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
            else { return }

            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                Log.ui.error("orientation request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    #endif
}
