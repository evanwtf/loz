import GameController
import NESCore

#if os(iOS)

    /// Apple's own on-screen controller, from the GameController framework.
    ///
    /// Worth having for one structural reason: `GCVirtualController` draws and
    /// hit-tests in a window the system owns, so its touch handling is entirely
    /// outside this app's SwiftUI view tree. Nothing the app does to that tree
    /// — including rebuilding it sixty times a second, which is what made the
    /// hand-written controls stop responding — can reach it. Input then arrives
    /// through the same `GCController` path as a physical pad, which was
    /// already wired up.
    ///
    /// It is not a free win. The appearance and placement are Apple's, the
    /// press callouts cannot be drawn on it, and the element set is fixed:
    /// there is no virtual Menu or Options button, so SELECT and START stay as
    /// ordinary buttons elsewhere on screen. They are pressed rarely enough
    /// that the trade is worth it, while the d-pad and A/B — the controls that
    /// actually have to feel right — come from the system.
    ///
    /// A single instance because the underlying resource is genuinely global:
    /// the virtual controller presents its own window over the whole app, and
    /// two of them would fight.
    @MainActor
    final class VirtualPad {
        static let shared = VirtualPad()

        private var virtual: GCVirtualController?

        /// The `GCController` the system vends for this pad, if connected.
        /// Used to tell it apart from a physical controller when binding
        /// buttons, since the two want different mappings.
        private(set) weak var controller: GCController?

        private init() {}

        var isConnected: Bool { virtual != nil }

        func connect() {
            guard virtual == nil else { return }

            let configuration = GCVirtualController.Configuration()
            // Only the controls that need to feel right. START and SELECT have
            // no virtual equivalent and are handled in the app's own UI.
            // A direction pad, not a thumbstick: this is a NES game and its
            // movement is eight-way. Note that requesting both is not allowed —
            // the app exits on connect — and that the simulator draws the face
            // buttons but not the left-hand element, so this configuration can
            // only be judged on a device.
            configuration.elements = [
                GCInputDirectionPad,
                GCInputButtonA,
                GCInputButtonB,
            ]

            let pad = GCVirtualController(configuration: configuration)
            virtual = pad
            // The completion runs off the main actor, so nothing non-Sendable
            // may be captured — `pad` itself least of all. Hop first, then read
            // the stored reference back on the main actor.
            pad.connect { [weak self] error in
                let message = error?.localizedDescription
                Task { @MainActor in
                    self?.finishConnecting(failure: message)
                }
            }
        }

        /// Split out rather than written inline in the completion handler.
        /// Touching properties there needs an explicit `self.`, which the
        /// formatter's `--self remove` rule then strips back out, so the code
        /// builds before formatting and not after. A method call sidesteps the
        /// argument entirely.
        private func finishConnecting(failure: String?) {
            if let failure {
                Log.ui.error("""
                virtual controller failed to connect: \
                \(failure, privacy: .public)
                """)
                virtual = nil
                return
            }
            controller = virtual?.controller
            Log.ui.notice("virtual controller connected")
        }

        func disconnect() {
            virtual?.disconnect()
            virtual = nil
            controller = nil
            Log.ui.notice("virtual controller disconnected")
        }
    }

#endif
