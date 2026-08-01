import NESCore
import SwiftUI

/// The game screen: a nearest-neighbour scaled framebuffer.
///
/// Sizes itself to the available width at a 4:3 aspect rather than filling and
/// letterboxing, so a caller can stack it against controls without the screen
/// floating in dead space.
public struct GameScreen: View {
    public let image: CGImage?

    public init(image: CGImage?) {
        self.image = image
    }

    public var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .interpolation(.none)     // never smooth pixel art
                    .antialiased(false)
                    .resizable()
            } else {
                Color.black
            }
        }
        // The NES pushed a 256x240 buffer to a 4:3 screen, so pixels were
        // slightly tall. Matching that is what makes the picture look right
        // rather than subtly squashed.
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .background(Color.black)
    }
}

/// Full player UI: screen, platform-appropriate controls, and an optional
/// diagnostics overlay.
public struct EmulatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var host: EmulatorHost
    @StateObject private var store: SaveStateStore
    @State private var showDiagnostics = LaunchOptions.showDiagnostics
    @State private var showMenu = LaunchOptions.openMenu

    public init(host: EmulatorHost) {
        self.host = host
        _store = StateObject(wrappedValue: SaveStateStore(
            gameName: host.gameName, romHash: host.romHash))
    }

    public var body: some View {
        content
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .onAppear { host.start() }
            .onDisappear { host.stop() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive, .background:
                    // Snapshot on .inactive as well as .background: it fires
                    // first and is where the system is most generous with time.
                    // Writing twice is harmless — the encode is sub-millisecond
                    // and the write is atomic.
                    host.persistForBackgrounding()
                    host.isPaused = true
                case .active:
                    // Do not un-pause if the menu is what paused us.
                    if !showMenu { host.isPaused = false }
                @unknown default:
                    break
                }
            }
            // The diagnostics overlay is placed per-layout rather than over the
            // whole view: on a phone it would otherwise sit on top of the
            // picture, which is the one thing it must not obscure. See
            // `content`.
            .overlay(alignment: .topTrailing) {
                if !showMenu { menuButton }
            }
            .overlay {
                if showMenu {
                    GameMenu(host: host, store: store,
                             isPresented: $showMenu,
                             showDiagnostics: $showDiagnostics)
                }
            }
            .modifier(KeyboardControls(host: host, showDiagnostics: $showDiagnostics))
            .modifier(GameControllerSupport(host: host))
    }

    /// The only permanent chrome. Small and translucent so it reads as part of
    /// the bezel rather than an emulator toolbar.
    private var menuButton: some View {
        Button {
            store.refresh()
            host.isPaused = true
            withAnimation(.easeOut(duration: 0.15)) { showMenu = true }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.45))
                .padding(10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    landscape(geometry.size)
                } else {
                    portrait(geometry.size)
                }
            }
        #else
            // macOS and tvOS drive input from keyboard or a game controller, so the
            // screen gets the whole window. With no controls to tuck it beside,
            // the overlay has nowhere to go but on top of the picture.
            GameScreen(image: host.frame)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if showDiagnostics { diagnostics() }
                }
        #endif
    }

    #if os(iOS)
        private func portrait(_ size: CGSize) -> some View {
            VStack(spacing: 0) {
                GameScreen(image: host.frame)
                    .frame(maxWidth: .infinity)
                // Controls take all remaining height and scale into it, rather than
                // sitting in a fixed strip with dead space above.
                TouchControls(host: host, layout: .portrait(size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The cluster sits at the bottom of this band, leaving a
                    // few hundred points of empty space directly beneath the
                    // screen. That is where the diagnostics belong: legible,
                    // and not covering the game.
                    .overlay(alignment: .topLeading) {
                        if showDiagnostics { diagnostics() }
                    }
            }
        }

        private func landscape(_ size: CGSize) -> some View {
            // Give the screen every pixel of height it can use, then hand whatever
            // is left over to the controls on either side. On a modern phone that
            // is comfortably enough for a full-size pad, so nothing overlaps the
            // picture.
            let screenWidth = min(size.height * (4.0 / 3.0), size.width * 0.62)
            let controlWidth = max((size.width - screenWidth) / 2, 0)

            return ZStack {
                GameScreen(image: host.frame)
                    .frame(width: screenWidth, height: size.height)

                TouchControls(
                    host: host,
                    layout: .landscape(controlWidth: controlWidth, height: size.height))
            }
            .frame(width: size.width, height: size.height)
            // A landscape side column is only ~164 pt wide and the callouts
            // claim the space directly above the cluster, so the readout goes
            // below it, in compact form. The full-width version wraps here and
            // collides with the pins.
            .overlay(alignment: .bottomLeading) {
                if showDiagnostics {
                    diagnostics(compact: true)
                        .frame(width: controlWidth, alignment: .leading)
                }
            }
        }
    #endif

    /// Pressed buttons as letters, or a dash when nothing is held.
    private static func padDescription(_ buttons: NESButton) -> String {
        let names: [(NESButton, String)] = [
            (.up, "U"), (.down, "D"), (.left, "L"), (.right, "R"),
            (.select, "sel"), (.start, "start"), (.b, "B"), (.a, "A"),
        ]
        let held = names.filter { buttons.contains($0.0) }.map(\.1)
        return held.isEmpty ? "—" : held.joined(separator: " ")
    }

    /// - Parameter compact: drop the emulator internals and shrink the type,
    ///   for places too narrow for the full readout. The frame and input
    ///   timings survive in both forms — they are the reason this exists.
    private func diagnostics(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.0f fps", host.framesPerSecond))
            // The frame budget, on screen. `gap` is the one that matters for
            // input latency: it is the spacing between ticks, so it counts
            // main-thread work this class never sees — SwiftUI re-evaluating
            // the view tree, chiefly. emulate+render small but gap large means
            // the cost is outside the emulator, and no amount of making the
            // emulator faster will help.
            Text(String(format: "emu %.1f  img %.1f ms",
                        host.profile.emulateMS, host.profile.renderMS))
            Text(String(format: "gap %.1f  max %.0f ms",
                        host.profile.gapMS, host.profile.worstGapMS))
            Text("late \(host.profile.lateTicks)/120")
                .foregroundStyle(host.profile.lateTicks > 6 ? .red : .green)
            // Finger-to-code latency, measured from the event's own timestamp.
            // This is the number the whole input investigation turns on.
            Text(String(format: "touch %.0f  max %.0f ms",
                        host.inputLatency.lastMS, host.inputLatency.worstMS))
                .foregroundStyle(host.inputLatency.worstMS > 100 ? .red : .green)
            if !compact {
                Text("bank \(host.nes.mapper.currentPRGBank)")
                Text(String(format: "PC $%04X", host.nes.cpu.pc))
                Text("scanline \(host.nes.ppu.scanline)")
            }
            // Live pad state. "The buttons do nothing" is ambiguous between
            // the press never arriving and the game ignoring it; this splits
            // those apart without a debugger or a cable.
            Text("pad \(Self.padDescription(host.nes.controller1.buttons))")
            // Which build this is. Saves guessing whether a fix is actually on
            // the device, which is otherwise unanswerable from the device.
            // Split across two lines so the block stays narrow enough for the
            // landscape control column.
            Text(BuildInfo.identity)
                .foregroundStyle(.green.opacity(0.7))
            Text(BuildInfo.builtStamp)
                .foregroundStyle(.green.opacity(0.7))
            if host.speedMultiplier > 1 {
                Text("\(host.speedMultiplier)x").foregroundStyle(.yellow)
            }
        }
        .font(.system(size: compact ? 9 : 11, weight: .medium, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
