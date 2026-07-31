import NESCore
import SwiftUI

#if os(iOS)

    /// On-screen controls, laid out for whichever orientation the device is in.
    ///
    /// Portrait stacks the screen above the pad. Landscape puts the pad and buttons
    /// either side of the screen, which both fills the space better and keeps
    /// thumbs off the picture.
    struct TouchControls: View {
        let host: EmulatorHost
        let layout: ControlLayout

        var body: some View {
            switch layout {
            case let .portrait(size):
                portrait(size)
            case let .landscape(controlWidth, height):
                landscape(controlWidth: controlWidth, height: height)
            }
        }

        // MARK: Portrait

        private func portrait(_ size: CGSize) -> some View {
            let margin: CGFloat = 20
            let usable = size.width - margin * 2
            let dpadSize = min(usable * 0.44, size.height * 0.62)
            let gap = usable * 0.06
            let column = usable - dpadSize - gap
            let buttonSize = min(column * 0.42, dpadSize * 0.46)

            return HStack(alignment: .center, spacing: gap) {
                DPadControl(host: host)
                    .frame(width: dpadSize, height: dpadSize)

                VStack(spacing: buttonSize * 0.34) {
                    systemRow(buttonSize: buttonSize)
                    actionRow(buttonSize: buttonSize)
                }
                .frame(width: column)
            }
            .padding(.horizontal, margin)
            // Sit toward the bottom: that is where thumbs actually rest.
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .padding(.bottom, size.height * 0.10)
        }

        // MARK: Landscape

        private func landscape(controlWidth: CGFloat, height: CGFloat) -> some View {
            let dpadSize = min(controlWidth * 0.92, height * 0.62)
            let buttonSize = min(controlWidth * 0.40, height * 0.28)

            return HStack(spacing: 0) {
                DPadControl(host: host)
                    .frame(width: dpadSize, height: dpadSize)
                    .frame(width: controlWidth, height: height, alignment: .center)

                Spacer(minLength: 0)

                VStack(spacing: buttonSize * 0.30) {
                    systemRow(buttonSize: buttonSize * 0.92)
                    actionRow(buttonSize: buttonSize)
                }
                .frame(width: controlWidth, height: height, alignment: .center)
            }
        }

        // MARK: Shared pieces

        private func systemRow(buttonSize: CGFloat) -> some View {
            HStack(spacing: buttonSize * 0.26) {
                SystemButton(title: "SELECT", button: .select, host: host,
                             width: buttonSize * 1.02)
                SystemButton(title: "START", button: .start, host: host,
                             width: buttonSize * 1.02)
            }
        }

        private func actionRow(buttonSize: CGFloat) -> some View {
            HStack(spacing: buttonSize * 0.34) {
                ActionButton(title: "B", button: .b, host: host, size: buttonSize)
                ActionButton(title: "A", button: .a, host: host, size: buttonSize)
                    .offset(y: -buttonSize * 0.26)
            }
        }
    }

    /// How the controls should arrange themselves.
    enum ControlLayout {
        case portrait(CGSize)
        /// Width available on each side of the screen, and the full height.
        case landscape(controlWidth: CGFloat, height: CGFloat)
    }

    // MARK: - D-pad

    /// A single tracked surface rather than four separate buttons.
    ///
    /// Zelda needs reliable diagonals, and discrete hit targets drop inputs when a
    /// thumb slides from one direction to another — which happens constantly when
    /// dodging.
    struct DPadControl: View {
        let host: EmulatorHost
        @State private var active: NESButton = []

        /// Ignore a small centre area so a resting thumb picks no direction.
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
                        .onEnded { _ in apply([]) }
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

        private func apply(_ next: NESButton) {
            guard next != active else { return }
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

    // MARK: - Buttons

    struct ActionButton: View {
        let title: String
        let button: NESButton
        let host: EmulatorHost
        var size: CGFloat = 74
        @State private var isPressed = false

        var body: some View {
            Circle()
                .fill(isPressed ? Color.red.opacity(0.85) : Color.red.opacity(0.55))
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                .overlay(
                    Text(title)
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.06), value: isPressed)
                .gesture(
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
                )
        }
    }

    struct SystemButton: View {
        let title: String
        let button: NESButton
        let host: EmulatorHost
        var width: CGFloat = 74
        @State private var isPressed = false

        var body: some View {
            Capsule()
                .fill(.white.opacity(isPressed ? 0.45 : 0.22))
                .overlay(
                    Text(title)
                        .font(.system(size: max(8, width * 0.14),
                                      weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                )
                .frame(width: width, height: width * 0.34)
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
