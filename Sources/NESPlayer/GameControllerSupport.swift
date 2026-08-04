import GameController
import NESCore
import SwiftUI

/// Binds MFi, Xbox, and DualSense controllers to the emulated pad.
///
/// Required on tvOS, where the Siri Remote is unusable for this game, and the
/// preferred input everywhere else.
struct GameControllerSupport: ViewModifier {
    let host: EmulatorHost
    /// Opens the app's own menu. Reached by holding the controller's Menu
    /// button, which on tvOS is the only route to it.
    let onMenu: () -> Void

    /// Distinguishes a tap of the Menu button from a hold.
    ///
    /// A small object rather than two `@State` properties because the
    /// controller handler is a closure captured once at attach time; it cannot
    /// see later values of a struct's state.
    @State private var holdToOpenMenu = MenuHold()

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

        // Deliver on the main queue and act immediately, rather than hopping
        // through a `Task` per event. The default queue is not the main one, so
        // every press was costing a scheduling round trip before it reached the
        // emulator — small, but it is pure latency on the one path where
        // latency is the whole point.
        controller.handlerQueue = .main

        let press: (NESButton) -> (GCControllerButtonInput, Float, Bool) -> Void = { button in
            { _, _, pressed in
                MainActor.assumeIsolated { host.setButton(button, pressed: pressed) }
            }
        }

        // Face buttons. A/B are swapped relative to the Xbox layout so that the
        // physical right-hand button is NES A, which is what muscle memory and
        // the on-screen layout both expect.
        pad.buttonA.pressedChangedHandler = press(.a)
        pad.buttonB.pressedChangedHandler = press(.b)
        // Mirror onto X/Y so either row works for rapid sword-and-item play.
        pad.buttonX.pressedChangedHandler = press(.b)
        pad.buttonY.pressedChangedHandler = press(.a)

        // Menu is both buttons it needs to be: a tap is NES START, a hold opens
        // the app's own menu.
        //
        // On tvOS that hold is the *only* way in. The ⋯ button is drawn and the
        // focus engine can reach it, but with a controller attached the d-pad
        // is steering Link rather than moving focus, so nothing takes the
        // player to it — the settings, the save slots and the toggles were
        // simply unreachable on that platform.
        //
        // Menu is the button a tvOS player reaches for, and the cost of sharing
        // it is that START arrives on release rather than on press. That is
        // fine for a button used to open the inventory and never in combat.
        pad.buttonMenu.pressedChangedHandler = { [holdToOpenMenu] _, _, pressed in
            MainActor.assumeIsolated {
                if pressed {
                    holdToOpenMenu.begin()
                } else if holdToOpenMenu.endedWithoutFiring() {
                    // A tap: send START as a pulse, since the press half has
                    // already been swallowed waiting to see if it was a hold.
                    host.setButton(.start, pressed: true)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        host.setButton(.start, pressed: false)
                    }
                }
            }
        }
        pad.buttonOptions?.pressedChangedHandler = press(.select)

        let steer: (GCControllerDirectionPad, Float, Float) -> Void = { _, xAxis, yAxis in
            MainActor.assumeIsolated {
                host.setButton(.left, pressed: xAxis < -0.5)
                host.setButton(.right, pressed: xAxis > 0.5)
                host.setButton(.down, pressed: yAxis < -0.5)
                host.setButton(.up, pressed: yAxis > 0.5)
            }
        }
        pad.dpad.valueChangedHandler = steer
        // The stick drives the same d-pad, with a generous dead zone so a
        // resting thumb does not creep Link into a wall.
        pad.leftThumbstick.valueChangedHandler = steer

        // Shoulder button for fast-forward, invaluable when exploring.
        pad.rightShoulder.pressedChangedHandler = { _, _, pressed in
            MainActor.assumeIsolated { host.speedMultiplier = pressed ? 4 : 1 }
        }

        // A DualShock or DualSense has one button the NES has no use for: the
        // touchpad click. It opens the menu outright, with no hold — the whole
        // problem on tvOS was that nothing obvious did, and a button spare on
        // the most common controller is the least surprising place to put it.
        let openMenu: (GCControllerButtonInput, Float, Bool) -> Void = { _, _, pressed in
            MainActor.assumeIsolated { if pressed { onMenu() } }
        }
        if let dualShock = pad as? GCDualShockGamepad {
            dualShock.touchpadButton.pressedChangedHandler = openMenu
        } else if let dualSense = pad as? GCDualSenseGamepad {
            dualSense.touchpadButton.pressedChangedHandler = openMenu
        }

        holdToOpenMenu.onFire = onMenu
    }
}

/// Times how long the Menu button is held, so a tap and a hold can mean
/// different things.
@MainActor
final class MenuHold {
    /// Long enough not to fire on a quick tap for START, short enough that a
    /// player who wants the menu does not think it is broken.
    static let threshold = Duration.milliseconds(500)

    private var fired = false
    private var pending: Task<Void, Never>?
    var onFire: (() -> Void)?

    func begin() {
        fired = false
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.threshold)
            guard let self, !Task.isCancelled else { return }
            fired = true
            onFire?()
        }
    }

    /// True when the button was released before the hold fired — meaning the
    /// press was a tap, and belongs to the game.
    func endedWithoutFiring() -> Bool {
        pending?.cancel()
        pending = nil
        return !fired
    }
}
