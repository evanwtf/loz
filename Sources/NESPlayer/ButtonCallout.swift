import NESCore
import SwiftUI

#if os(iOS)

    /// A map-pin label naming a button that is held right now.
    ///
    /// The on-screen controls have a problem no physical pad has: the thing
    /// that would show you a press is underneath the finger making it. A
    /// highlight drawn on the control itself is therefore invisible exactly
    /// when it matters, which is why the first attempt — a dot on the pressed
    /// d-pad arm — did not answer "did that register?" at all.
    ///
    /// So the feedback is moved somewhere a thumb never covers: the empty band
    /// between the picture and the controls, with the pin pointing back down at
    /// the cluster it belongs to.
    struct ButtonCallout: View {
        let title: String

        var body: some View {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.95)))
                PinPointer()
                    .fill(.white.opacity(0.95))
                    .frame(width: 10, height: 6)
            }
            // Never eat a touch. These exist to diagnose input latency; a
            // callout that intercepted a press would be self-defeating.
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    /// The downward tail that makes the label read as pointing at something.
    private struct PinPointer: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }

    /// The callouts for one cluster, laid out in a row above it.
    struct CalloutRow: View {
        let held: NESButton
        /// Which buttons this row is responsible for, and what to call them.
        let names: [(button: NESButton, title: String)]

        /// Reserved height, so the row occupies the same space empty or full.
        ///
        /// Without this the cluster moves the moment a callout appears — the
        /// controls would shift under the thumb that is pressing them, which is
        /// a worse problem than the one the callouts solve.
        static let height: CGFloat = 34

        var body: some View {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<names.count, id: \.self) { index in
                    if held.contains(names[index].button) {
                        ButtonCallout(title: names[index].title)
                    }
                }
            }
            .frame(height: Self.height, alignment: .bottom)
            .animation(.easeOut(duration: 0.08), value: held.rawValue)
            .allowsHitTesting(false)
        }

        /// The d-pad's four directions, in reading order.
        static let directions: [(button: NESButton, title: String)] = [
            (.up, "UP"), (.down, "DOWN"), (.left, "LEFT"), (.right, "RIGHT"),
        ]

        /// Everything in the right-hand column.
        static let actions: [(button: NESButton, title: String)] = [
            (.select, "SELECT"), (.start, "START"), (.b, "B"), (.a, "A"),
        ]
    }

#endif
