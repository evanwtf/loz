import SwiftUI
import GameController
import NESCore

/// Binds MFi, Xbox, and DualSense controllers to the emulated pad.
///
/// Required on tvOS, where the Siri Remote is unusable for this game, and the
/// preferred input everywhere else.
struct GameControllerSupport: ViewModifier {
    let host: EmulatorHost

    func body(content: Content) -> some View {
        content
            .task {
                attachExisting()
                await observeConnections()
            }
    }

    private func attachExisting() {
        for controller in GCController.controllers() {
            attach(controller)
        }
        GCController.startWirelessControllerDiscovery()
    }

    private func observeConnections() async {
        let notifications = NotificationCenter.default.notifications(
            named: .GCControllerDidConnect)
        for await note in notifications {
            if let controller = note.object as? GCController {
                attach(controller)
            }
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }

        // Face buttons. A/B are swapped relative to the Xbox layout so that the
        // physical right-hand button is NES A, which is what muscle memory and
        // the on-screen layout both expect.
        pad.buttonA.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.setButton(.a, pressed: pressed) }
        }
        pad.buttonB.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.setButton(.b, pressed: pressed) }
        }
        // Mirror onto X/Y so either row works for rapid sword-and-item play.
        pad.buttonX.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.setButton(.b, pressed: pressed) }
        }
        pad.buttonY.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.setButton(.a, pressed: pressed) }
        }

        pad.buttonMenu.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.setButton(.start, pressed: pressed) }
        }
        pad.buttonOptions?.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.setButton(.select, pressed: pressed) }
        }

        pad.dpad.valueChangedHandler = { _, xAxis, yAxis in
            Task { @MainActor in
                host.setButton(.left, pressed: xAxis < -0.5)
                host.setButton(.right, pressed: xAxis > 0.5)
                host.setButton(.down, pressed: yAxis < -0.5)
                host.setButton(.up, pressed: yAxis > 0.5)
            }
        }

        // The stick drives the same d-pad, with a generous dead zone so a
        // resting thumb does not creep Link into a wall.
        pad.leftThumbstick.valueChangedHandler = { _, xAxis, yAxis in
            Task { @MainActor in
                host.setButton(.left, pressed: xAxis < -0.5)
                host.setButton(.right, pressed: xAxis > 0.5)
                host.setButton(.down, pressed: yAxis < -0.5)
                host.setButton(.up, pressed: yAxis > 0.5)
            }
        }

        // Shoulder button for fast-forward, invaluable when exploring.
        pad.rightShoulder.pressedChangedHandler = { _, _, pressed in
            Task { @MainActor in host.speedMultiplier = pressed ? 4 : 1 }
        }
    }
}
