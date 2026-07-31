import Foundation

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

    /// Starts with the diagnostics overlay visible.
    public static var showDiagnostics: Bool {
        UserDefaults.standard.bool(forKey: "nesDiagnostics")
    }

    /// Starts muted — useful when capturing screenshots in bulk.
    public static var startMuted: Bool {
        UserDefaults.standard.bool(forKey: "nesMuted")
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
                print("orientation: request failed — \(error)")
            }
        }
    #endif
}
