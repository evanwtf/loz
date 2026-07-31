import GameController
import NESCore
import SwiftUI

/// Binds MFi, Xbox, and DualSense controllers to the emulated pad.
///
/// Required on tvOS, where the Siri Remote is unusable for this game, and the
/// preferred input everywhere else.
struct GameControllerSupport: ViewModifier {
    let host: EmulatorHost

    /// Whether any usable gamepad is currently attached. Only surfaced on
    /// tvOS, where it is the difference between "playable" and "appears
    /// broken" — there is no touchscreen fallback.
    @State private var hasController = false

    func body(content: Content) -> some View {
        content
            .task {
                attachExisting()
                await observeConnections()
            }
        #if os(tvOS)
            .overlay(alignment: .bottom) {
                if !hasController { controllerHint }
            }
        #endif
    }

    #if os(tvOS)
        private var controllerHint: some View {
            VStack(spacing: 10) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 40))
                Text("Connect a game controller")
                    .font(.title3.weight(.semibold))
                Text("The Siri Remote cannot play this game. "
                    + "Pair an Xbox, DualSense, or MFi controller in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .padding(28)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
            .padding(.bottom, 60)
        }
    #endif

    private func attachExisting() {
        for controller in GCController.controllers() {
            attach(controller)
        }
        hasController = GCController.controllers().contains { $0.extendedGamepad != nil }
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
        hasController = true

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
