import SwiftUI
import NESCore

#if os(iOS)

/// On-screen controls for iPhone and iPad.
///
/// The d-pad is a single tracked surface rather than four separate buttons:
/// Zelda needs reliable diagonals, and separate hit targets make sliding from
/// one direction to another drop inputs.
struct TouchControls: View {
    let host: EmulatorHost

    var body: some View {
        HStack(alignment: .center) {
            DPad(host: host)
                .frame(width: 180, height: 180)

            Spacer(minLength: 0)

            VStack(spacing: 22) {
                HStack(spacing: 18) {
                    SystemButton(title: "SELECT", button: .select, host: host)
                    SystemButton(title: "START", button: .start, host: host)
                }
                HStack(spacing: 26) {
                    ActionButton(title: "B", button: .b, host: host)
                    ActionButton(title: "A", button: .a, host: host)
                        .offset(y: -18)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color.black)
    }
}

private struct DPad: View {
    let host: EmulatorHost
    @State private var active: NESButton = []

    /// Ignore a small centre area so a resting thumb does not pick a direction.
    private let deadZone: CGFloat = 0.18

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            ZStack {
                Image(systemName: "dpad.fill")
                    .resizable()
                    .foregroundStyle(.white.opacity(0.22))
                Image(systemName: "dpad")
                    .resizable()
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in update(value.location, in: size) }
                    .onEnded { _ in clear() }
            )
        }
    }

    private func update(_ location: CGPoint, in size: CGFloat) {
        // Normalise to -1...1 around the centre.
        let dx = (location.x / size) * 2 - 1
        let dy = (location.y / size) * 2 - 1

        var next: NESButton = []
        if abs(dx) > deadZone { next.insert(dx < 0 ? .left : .right) }
        if abs(dy) > deadZone { next.insert(dy < 0 ? .up : .down) }

        guard next != active else { return }
        apply(next)
    }

    private func clear() {
        guard !active.isEmpty else { return }
        apply([])
    }

    private func apply(_ next: NESButton) {
        for direction in [NESButton.up, .down, .left, .right] {
            let wasHeld = active.contains(direction)
            let isHeld = next.contains(direction)
            if wasHeld != isHeld {
                host.setButton(direction, pressed: isHeld)
            }
        }
        active = next
        if !next.isEmpty {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.3)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let button: NESButton
    let host: EmulatorHost
    @State private var isPressed = false

    var body: some View {
        Circle()
            .fill(isPressed ? Color.red.opacity(0.85) : Color.red.opacity(0.55))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
            .overlay(
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .frame(width: 74, height: 74)
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.06), value: isPressed)
            .gesture(press)
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                host.setButton(button, pressed: true)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .onEnded { _ in
                isPressed = false
                host.setButton(button, pressed: false)
            }
    }
}

private struct SystemButton: View {
    let title: String
    let button: NESButton
    let host: EmulatorHost
    @State private var isPressed = false

    var body: some View {
        Capsule()
            .fill(.white.opacity(isPressed ? 0.45 : 0.22))
            .overlay(
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .frame(width: 74, height: 26)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        host.setButton(button, pressed: true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        host.setButton(button, pressed: false)
                    }
            )
    }
}

#endif
