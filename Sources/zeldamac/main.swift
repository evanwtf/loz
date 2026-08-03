// This whole file is macOS-only.
//
// The Xcode app projects reference this package locally, so Xcode resolves and
// indexes *every* target for whatever platform is selected — including this
// one, which is a macOS executable and imports AppKit. Building the tvOS app
// therefore failed with "Unable to resolve module dependency: 'AppKit'" even
// though nothing in that app depends on `zeldamac`.
//
// `swift build` never sees it: it builds for the host, where AppKit exists.
#if os(macOS)

    import AppKit
    import NESPlayer
    import SwiftUI
    import ZeldaGame

    // A macOS build that runs straight from SwiftPM — `swift run zeldamac` — with
    // no Xcode project. This is the fast iteration loop: no signing, no device
    // deploy, relaunch in a second while working on the PPU or a decompiled routine.

    let arguments = CommandLine.arguments.dropFirst()
    let romPath = arguments.first(where: { !$0.hasPrefix("-") })
        ?? FileManager.default.currentDirectoryPath + "/zelda.nes"
    let romURL = URL(fileURLWithPath: romPath)

    // Headless check of the whole host — emulation, framebuffer, and audio — with
    // no window and no display link. Lets the macOS path be verified over SSH, on a
    // sleeping display, or in CI, none of which can drive a real frame clock.
    if arguments.contains("--selftest") {
        MainActor.assumeIsolated {
            do {
                let data = try Data(contentsOf: romURL)
                let host = try EmulatorHost(game: Zelda.self, romData: [UInt8](data))

                let frames = 300
                let start = Date()
                for _ in 0..<frames { host.tick() }
                let elapsed = Date().timeIntervalSince(start)

                let distinctColours = Set(host.nes.framebuffer).count
                // 300 frames is 5 seconds of game time, so ~44100*5 samples.
                let expectedSamples = Int(44100.0 * Double(frames) / 60.0)
                let produced = host.totalAudioSamples
                let audioRatio = Double(produced) / Double(expectedSamples)

                print("""
                self-test: \(Zelda.title)
                  frames rendered:   \(frames) in \(String(format: "%.2f", elapsed))s \
                (\(String(format: "%.0f", Double(frames) / elapsed)) fps headroom)
                  framebuffer image: \(host.frame != nil ? "present" : "MISSING")
                  distinct colours:  \(distinctColours)
                  audio produced:    \(produced) / \(expectedSamples) expected \
                (\(String(format: "%.1f%%", audioRatio * 100)))
                """)

                let healthy = host.frame != nil
                    && distinctColours > 2
                    && audioRatio > 0.95 && audioRatio < 1.05
                print(healthy ? "PASS" : "FAIL")
                exit(healthy ? 0 : 1)
            } catch {
                print("self-test FAILED: \(error)")
                exit(1)
            }
        }
    }

    final class AppDelegate: NSObject, NSApplicationDelegate {
        var window: NSWindow?

        func applicationDidFinishLaunching(_: Notification) {
            // 4:3 at a comfortable integer-ish scale.
            let size = NSSize(width: 768, height: 720)

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)

            window.title = Zelda.title
            window.contentView = NSHostingView(
                rootView: GameLauncher(game: Zelda.self, romURL: romURL))
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.setFrameAutosaveName("ZeldaWindow")
            // Keyboard input goes through SwiftUI's focus system, so the hosting
            // view has to actually be first responder.
            window.makeFirstResponder(window.contentView)

            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            true
        }
    }

    let app = NSApplication.shared
    // A SwiftPM executable is not an app bundle, so it defaults to a background
    // accessory. Without this the window never takes focus and keys go nowhere.
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()

#endif
