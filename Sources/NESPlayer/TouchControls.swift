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

        /// Which buttons are held, hoisted out of the individual controls so
        /// the callouts can be drawn away from the fingers causing them. This
        /// is set on exactly the transitions that call `host.setButton`, so a
        /// callout means "the emulator has been told" — which makes it a
        /// readout of input latency as well as of state.
        @State private var held: NESButton = LaunchOptions.forcedHeldButtons

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

            return VStack(spacing: 10) {
                // Callouts sit directly above the cluster they describe, in
                // space that is otherwise empty, so each pin points at its own
                // group rather than at a shared strip.
                HStack(alignment: .bottom, spacing: metrics.gap) {
                    CalloutRow(held: held, names: CalloutRow.directions)
                        .frame(width: metrics.dpadSize)
                    CalloutRow(held: held, names: CalloutRow.actions)
                        .frame(width: metrics.columnWidth)
                }

                HStack(alignment: .center, spacing: metrics.gap) {
                    DPadControl(host: host, size: metrics.dpadSize, held: $held)

                    VStack(spacing: metrics.buttonSize * 0.34) {
                        systemRow(buttonSize: metrics.buttonSize)
                        actionRow(buttonSize: metrics.buttonSize)
                    }
                    .frame(width: metrics.columnWidth)
                }
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
                column(width: controlWidth, height: height,
                       callouts: CalloutRow.directions)
                {
                    DPadControl(host: host, size: metrics.dpadSize, held: $held)
                }

                Spacer(minLength: 0)

                column(width: controlWidth, height: height,
                       callouts: CalloutRow.actions)
                {
                    VStack(spacing: metrics.buttonSize * 0.30) {
                        systemRow(buttonSize: metrics.buttonSize * 0.92)
                        actionRow(buttonSize: metrics.buttonSize)
                    }
                }
            }
        }

        /// One landscape side column: the cluster centred, its callouts pinned
        /// just above it in the dead space the centring leaves behind.
        private func column(
            width: CGFloat,
            height: CGFloat,
            callouts: [(button: NESButton, title: String)],
            @ViewBuilder content: () -> some View
        ) -> some View {
            VStack(spacing: 10) {
                CalloutRow(held: held, names: callouts)
                content()
            }
            .frame(width: width, height: height, alignment: .center)
        }

        // MARK: Shared pieces

        private func systemRow(buttonSize: CGFloat) -> some View {
            HStack(spacing: buttonSize * 0.26) {
                SystemButton(title: "SELECT", button: .select, host: host,
                             width: buttonSize * 1.02, held: $held)
                SystemButton(title: "START", button: .start, host: host,
                             width: buttonSize * 1.02, held: $held)
            }
        }

        private func actionRow(buttonSize: CGFloat) -> some View {
            HStack(spacing: buttonSize * 0.34) {
                ActionButton(title: "B", button: .b, host: host,
                             size: buttonSize, held: $held)
                ActionButton(title: "A", button: .a, host: host,
                             size: buttonSize, held: $held)
                    .offset(y: -buttonSize * 0.26)
            }
        }
    }

    // MARK: - D-pad

    /// A single tracked surface rather than four buttons. Direction selection
    /// lives in `DPadGeometry` so it can be tested without a touch.
    struct DPadControl: View {
        let host: EmulatorHost
        /// Edge length, passed in rather than measured.
        ///
        /// This used to wrap the pad in a `GeometryReader` to discover its own
        /// size. That made the pad the only control whose gesture lived inside
        /// a layout container that re-resolves on every published frame — 60
        /// times a second — while `ActionButton` and `SystemButton` are plain
        /// leaves. It was also the only control that needed a 300–1000 ms hold
        /// before a press registered, on a device where A and B were instant.
        /// `ControlMetrics` already knows this number, so the measurement was
        /// never necessary.
        let size: CGFloat
        @Binding var held: NESButton

        private static let directions: [NESButton] = [.up, .down, .left, .right]

        private var active: NESButton {
            held.intersection(NESButton(Self.directions))
        }

        var body: some View {
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
                        host.noteInputEvent(at: value.time)
                        apply(DPadGeometry.direction(at: value.location, in: size))
                    }
                    .onEnded { _ in apply([]) })
        }

        private func apply(_ next: NESButton) {
            let current = active
            guard next != current else { return }
            for direction in Self.directions {
                let wasHeld = current.contains(direction)
                let isHeld = next.contains(direction)
                if wasHeld != isHeld {
                    host.setButton(direction, pressed: isHeld)
                }
            }
            held.subtract(NESButton(Self.directions))
            held.formUnion(next)
            if !next.isEmpty { Haptics.direction() }
        }
    }

    // MARK: - Buttons

    struct ActionButton: View {
        let title: String
        let button: NESButton
        let host: EmulatorHost
        var size: CGFloat = 74
        @Binding var held: NESButton
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
                        .onChanged { value in
                            host.noteInputEvent(at: value.time)
                            guard !isPressed else { return }
                            isPressed = true
                            host.setButton(button, pressed: true)
                            held.insert(button)
                            Haptics.action()
                        }
                        .onEnded { _ in
                            isPressed = false
                            host.setButton(button, pressed: false)
                            held.remove(button)
                        })
        }
    }

    struct SystemButton: View {
        let title: String
        let button: NESButton
        let host: EmulatorHost
        var width: CGFloat = 74
        @Binding var held: NESButton
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
                        .onChanged { value in
                            host.noteInputEvent(at: value.time)
                            guard !isPressed else { return }
                            isPressed = true
                            host.setButton(button, pressed: true)
                            held.insert(button)
                            Haptics.system()
                        }
                        .onEnded { _ in
                            isPressed = false
                            host.setButton(button, pressed: false)
                            held.remove(button)
                        })
        }
    }

#endif
