import NESCore
import SwiftUI

#if os(iOS)

    /// On-screen controls, laid out for whichever orientation the device is in.
    ///
    /// Portrait stacks the screen above the pad. Landscape puts the pad and
    /// buttons either side of the screen, which both fills the space better and
    /// keeps thumbs off the picture.
    ///
    /// All sizing comes from `ControlMetrics`, which is plain geometry with no
    /// SwiftUI in it and is covered by tests.
    struct TouchControls: View {
        let host: EmulatorHost
        let layout: ControlLayout

        var body: some View {
            switch layout {
            case .portrait:
                // Measure locally rather than trusting the size handed down.
                //
                // In portrait this view sits below the screen in a VStack, so
                // its height is only what is left over. Sizing against the full
                // window height pushed the whole cluster off the bottom of the
                // display — invisible, and the game looked like it had no
                // controls at all.
                GeometryReader { geometry in
                    portrait(geometry.size)
                }
            case let .landscape(controlWidth, height):
                landscape(controlWidth: controlWidth, height: height)
            }
        }

        // MARK: Portrait

        private func portrait(_ size: CGSize) -> some View {
            let metrics = ControlMetrics.portrait(in: size)

            return HStack(alignment: .center, spacing: metrics.gap) {
                DPadControl(host: host)
                    .frame(width: metrics.dpadSize, height: metrics.dpadSize)

                VStack(spacing: metrics.buttonSize * 0.34) {
                    systemRow(buttonSize: metrics.buttonSize)
                    actionRow(buttonSize: metrics.buttonSize)
                }
                .frame(width: metrics.columnWidth)
            }
            .padding(.horizontal, metrics.margin)
            // The inset must be applied *inside* the frame. Outside it, the
            // frame has already claimed the full height, so the padding cannot
            // push anything up — it just overflows below the container and is
            // clipped, leaving the cluster flush against the bottom of the
            // display. That put the d-pad's DOWN key half off-screen and inside
            // the home-indicator gesture strip, where the system withholds
            // touches from the app while its own recogniser decides.
            .padding(.bottom, metrics.bottomInset)
            // Sit toward the bottom: that is where thumbs actually rest.
            .frame(width: size.width, height: size.height, alignment: .bottom)
        }

        // MARK: Landscape

        private func landscape(controlWidth: CGFloat, height: CGFloat) -> some View {
            let metrics = ControlMetrics.landscape(controlWidth: controlWidth, height: height)

            return HStack(spacing: 0) {
                DPadControl(host: host)
                    .frame(width: metrics.dpadSize, height: metrics.dpadSize)
                    .frame(width: controlWidth, height: height, alignment: .center)

                Spacer(minLength: 0)

                VStack(spacing: metrics.buttonSize * 0.30) {
                    systemRow(buttonSize: metrics.buttonSize * 0.92)
                    actionRow(buttonSize: metrics.buttonSize)
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

    // MARK: - D-pad

    /// A single tracked surface rather than four buttons. Direction selection
    /// lives in `DPadGeometry` so it can be tested without a touch.
    struct DPadControl: View {
        let host: EmulatorHost
        @State private var active: NESButton = []

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
                        .onChanged { value in
                            apply(DPadGeometry.direction(at: value.location, in: size))
                        }
                        .onEnded { _ in apply([]) })
            }
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
            if !next.isEmpty { Haptics.direction() }
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
                        .foregroundStyle(.white))
                .frame(width: size, height: size)
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.06), value: isPressed)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressed else { return }
                            isPressed = true
                            host.setButton(button, pressed: true)
                            Haptics.action()
                        }
                        .onEnded { _ in
                            isPressed = false
                            host.setButton(button, pressed: false)
                        })
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
                        .minimumScaleFactor(0.6))
                .frame(width: width, height: width * 0.34)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressed else { return }
                            isPressed = true
                            host.setButton(button, pressed: true)
                            Haptics.system()
                        }
                        .onEnded { _ in
                            isPressed = false
                            host.setButton(button, pressed: false)
                        })
        }
    }

#endif
