import GameController
import SwiftUI

/// A deliberately tiny app: Apple's on-screen controller, and a dot it moves.
///
/// The point is what it leaves out. The real app has an emulator on the main
/// actor, a frame clock, an audio engine, a published picture and a SwiftUI
/// control tree — and when input misbehaved, every one of those was a
/// candidate. Several rounds went into eliminating them one at a time.
///
/// Here there is nothing to eliminate. If the d-pad appears and the dot tracks
/// a thumb, `GCVirtualController` is sound and any remaining fault is ours. If
/// it does not, the problem is in the framework or in how it is configured,
/// and no amount of work on the emulator would ever have fixed it.
@main
struct PadTestApp: App {
    var body: some Scene {
        WindowGroup {
            PadTestView()
        }
    }
}

@MainActor
final class PadState: ObservableObject {
    /// Where the dot is, in points from the centre.
    @Published var offset = CGSize.zero
    /// What the pad currently reports, for display.
    @Published var reading = "—"
    /// Which elements the system actually gave us, which is the open question.
    @Published var status = "connecting…"
    /// Buttons, shown as they are pressed.
    @Published var buttons = ""

    private var virtual: GCVirtualController?
    private var mover: Timer?
    private var velocity = CGVector.zero

    func start() {
        let configuration = GCVirtualController.Configuration()
        configuration.elements = [
            GCInputDirectionPad,
            GCInputButtonA,
            GCInputButtonB,
        ]

        let pad = GCVirtualController(configuration: configuration)
        virtual = pad
        pad.connect { [weak self] error in
            let message = error?.localizedDescription
            Task { @MainActor in self?.connected(failure: message) }
        }

        // Move on a timer rather than on each controller event, so the dot
        // glides while a direction is held. Any stutter here is the app's own,
        // not the pad's.
        mover = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.offset.width += self.velocity.dx
                self.offset.height += self.velocity.dy
            }
        }
    }

    private func connected(failure: String?) {
        if let failure {
            status = "connect failed: \(failure)"
            return
        }
        guard let controller = virtual?.controller else {
            status = "connected, but no GCController"
            return
        }
        guard let pad = controller.extendedGamepad else {
            status = "controller has no extendedGamepad"
            return
        }

        // Report exactly which elements exist. If the d-pad is missing from
        // the drawn controller, this is where it shows up.
        let names = pad.allElements.compactMap { element -> String? in
            guard let name = element.localizedName else { return nil }
            return element === pad.dpad ? "\(name) (dpad)" : name
        }
        status = names.isEmpty ? "no elements" : names.sorted().joined(separator: ", ")

        controller.handlerQueue = .main
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.velocity = CGVector(dx: CGFloat(x) * 4, dy: CGFloat(-y) * 4)
                self.reading = String(format: "x %.2f  y %.2f", x, y)
            }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.note("A", pressed) }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.note("B", pressed) }
        }
    }

    private func note(_ name: String, _ pressed: Bool) {
        buttons = pressed ? name : ""
        if pressed { offset = .zero }
    }
}

struct PadTestView: View {
    @StateObject private var pad = PadState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Circle()
                .fill(.green)
                .frame(width: 44, height: 44)
                .offset(pad.offset)

            VStack(alignment: .leading, spacing: 6) {
                Text("Apple virtual controller test")
                    .font(.headline)
                Text(pad.status)
                Text("dpad  \(pad.reading)")
                Text("button \(pad.buttons.isEmpty ? "—" : pad.buttons)")
                Text("A recentres the dot")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { pad.start() }
    }
}
