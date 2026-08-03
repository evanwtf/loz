import NESCore
import SwiftUI

/// Carries the picture, and nothing else.
///
/// Exists so that a view drawing the game does not drag every sibling into a
/// rebuild sixty times a second. See `EmulatorHost.frames`.
@MainActor
public final class FrameStream: ObservableObject {
    @Published public internal(set) var image: CGImage?

    /// When the current image was produced, and how many have been produced.
    /// Deliberately unpublished: they are read alongside `image`, and
    /// publishing them would double the invalidations for no gain.
    public internal(set) var producedAt: CFAbsoluteTime = 0
    public internal(set) var produced = 0

    /// Presentation accounting, written by the view that actually draws.
    ///
    /// Frames produced and frames *shown* are different numbers, and the gap
    /// between them is invisible from the emulator side: a screen recording
    /// caught the picture unchanged for twenty seconds while the frame clock
    /// reported a steady 60 fps. Emulating a frame is not the same as anyone
    /// seeing it, and only the drawing view knows which happened.
    public internal(set) var presented = 0
    public internal(set) var lastStaleMS: Double = 0
    public internal(set) var worstStaleMS: Double = 0

    public init() {}

    /// Called by `GameScreen` when a new image reaches the display.
    func notePresented() {
        presented += 1
        let ms = (CFAbsoluteTimeGetCurrent() - producedAt) * 1000
        lastStaleMS = ms
        worstStaleMS = max(worstStaleMS, ms)
    }

    /// Records a freshly rendered picture.
    func publish(_ image: CGImage?) {
        producedAt = CFAbsoluteTimeGetCurrent()
        produced += 1
        self.image = image
    }
}

/// The game screen: a nearest-neighbour scaled framebuffer.
///
/// Sizes itself to the available width at a 4:3 aspect rather than filling and
/// letterboxing, so a caller can stack it against controls without the screen
/// floating in dead space.
public struct GameScreen: View {
    @ObservedObject private var stream: FrameStream

    public init(stream: FrameStream) {
        self.stream = stream
    }

    public var body: some View {
        Group {
            if let image = stream.image {
                Image(decorative: image, scale: 1.0)
                    .interpolation(.none)     // never smooth pixel art
                    .antialiased(false)
                    .resizable()
            } else {
                Color.black
            }
        }
        // Fires after this view has taken the new image, which is the closest
        // signal available to "it is on the glass". Counting here rather than
        // where frames are produced is the whole point: the two numbers
        // diverged badly and nothing upstream could tell.
        .onChange(of: stream.produced) { _, _ in
            stream.notePresented()
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
    @State private var showTapTest = LaunchOptions.openTapTest

    /// Use Apple's `GCVirtualController` instead of the hand-drawn pad.
    /// Persisted, because it is a preference about how the game feels rather
    /// than a debugging switch.
    @AppStorage("nesSystemControls") private var useSystemControls = false

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
            .onDisappear {
                host.stop()
                #if os(iOS)
                    VirtualPad.shared.disconnect()
                #endif
            }
        #if os(iOS)
            // `initial: true` so the pad is present at launch when the
            // preference is already on, not only when it is toggled.
            .onChange(of: useSystemControls, initial: true) { _, on in
                if on {
                    // Apple's pad only draws its d-pad in landscape, so turning
                    // it on in portrait would leave the game with A and B and no
                    // way to move. Ask for landscape rather than hand someone
                    // controls that cannot walk.
                    LaunchOptions.requestLandscape()
                    VirtualPad.shared.connect()
                } else {
                    VirtualPad.shared.disconnect()
                }
            }
        #endif
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
                             showDiagnostics: $showDiagnostics,
                             showTapTest: $showTapTest)
                }
            }
        #if os(iOS)
            .overlay {
                if showTapTest {
                    TapTest(host: host, isPresented: $showTapTest)
                }
            }
        #endif
            .modifier(KeyboardControls(host: host, showDiagnostics: $showDiagnostics))
            .modifier(GameControllerSupport(host: host))
        #if os(iOS)
            // Zero-sized and non-interactive: it exists only to reach the
            // window and attach a recogniser that observes touches without
            // taking any.
            .background {
                TouchLatencyProbe(host: host)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        #endif
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
            if useSystemControls {
                systemControls
            } else {
                GeometryReader { geometry in
                    if geometry.size.width > geometry.size.height {
                        landscape(geometry.size)
                    } else {
                        portrait(geometry.size)
                    }
                }
            }
        #else
            // macOS and tvOS drive input from keyboard or a game controller, so the
            // screen gets the whole window. With no controls to tuck it beside,
            // the overlay has nowhere to go but on top of the picture.
            GameScreen(stream: host.frames)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if showDiagnostics { diagnostics() }
                }
        #endif
    }

    #if os(iOS)
        /// Somewhere for the SELECT/START buttons to report press state when
        /// nothing is drawing callouts. Apple's pad has no callouts to feed.
        private static let sinkHeld = HeldButtons()

        /// Layout for Apple's virtual controller.
        ///
        /// The pad lives in a system window over this one, so the app draws
        /// only the picture and gets out of the way. SELECT and START have no
        /// virtual equivalent, so they stay as ordinary buttons — placed at the
        /// top, away from where the thumbs rest, since Zelda needs them
        /// occasionally rather than constantly.
        private var systemControls: some View {
            GameScreen(stream: host.frames)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if showDiagnostics { diagnostics(compact: true) }
                }
                .overlay(alignment: .top) { selectStartRow }
        }

        private var selectStartRow: some View {
            HStack(spacing: 10) {
                SystemButton(title: "SELECT", button: .select, host: host,
                             width: 86, held: Self.sinkHeld)
                SystemButton(title: "START", button: .start, host: host,
                             width: 86, held: Self.sinkHeld)
            }
            .padding(.top, 6)
        }

        private func portrait(_ size: CGSize) -> some View {
            VStack(spacing: 0) {
                GameScreen(stream: host.frames)
                    .frame(maxWidth: .infinity)
                // A full-width box immediately below the picture. Laid out in
                // the stack rather than floated over the controls, so it
                // reserves its own space instead of sitting on top of whatever
                // is beneath it.
                if showDiagnostics {
                    diagnostics(wide: true)
                }
                // Controls take all remaining height and scale into it, rather than
                // sitting in a fixed strip with dead space above.
                TouchControls(host: host, layout: .portrait(size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private func landscape(_ size: CGSize) -> some View {
            // Give the screen every pixel of height it can use, then hand whatever
            // is left over to the controls on either side. On a modern phone that
            // is comfortably enough for a full-size pad, so nothing overlaps the
            // picture.
            let screenWidth = min(size.height * (4.0 / 3.0), size.width * 0.62)
            let controlWidth = max((size.width - screenWidth) / 2, 0)

            // Reserve the bottom of the side columns for the readout, and give
            // the controls the rest. Floating it over them instead put the box
            // straight through the d-pad.
            let readoutHeight: CGFloat = showDiagnostics ? 170 : 0

            return ZStack(alignment: .top) {
                GameScreen(stream: host.frames)
                    .frame(width: screenWidth, height: size.height)

                VStack(spacing: 0) {
                    TouchControls(
                        host: host,
                        layout: .landscape(
                            controlWidth: controlWidth,
                            height: size.height - readoutHeight))

                    if showDiagnostics {
                        HStack(spacing: 0) {
                            diagnostics(compact: true, wide: true)
                                .frame(width: controlWidth, alignment: .leading)
                            Spacer(minLength: 0)
                        }
                        .frame(height: readoutHeight)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    #endif

    private func diagnostics(compact: Bool = false, wide: Bool = false) -> some View {
        DiagnosticsOverlay(
            stream: host.diagnostics, host: host, compact: compact, wide: wide)
    }
}

/// The on-screen readout.
///
/// A separate view observing `DiagnosticsStream` rather than the host, so that
/// counters updating at frame rate rebuild this and nothing else. Folded into
/// `EmulatorView` it would have invalidated the controls along with itself.
struct DiagnosticsOverlay: View {
    @ObservedObject var stream: DiagnosticsStream
    let host: EmulatorHost
    var compact = false
    /// Stretch to the full width available, as a laid-out box rather than a
    /// floating label.
    var wide = false

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
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.0f fps emulated", stream.framesPerSecond))
            // The headline number. Frames the display actually took, and how
            // old the picture on screen is. Unlike a callout or a latency
            // sample, this does not need a press to show the problem — it is
            // running whether or not anyone is touching the screen.
            Text(String(format: "%.0f fps SHOWN", stream.presentation.shownPerSecond))
                .foregroundStyle(stream.presentation.shownPerSecond < 45 ? .red : .green)
            Text(String(format: "stale %.0f max %.0f ms",
                        stream.presentation.staleMS,
                        stream.presentation.worstStaleMS))
                .foregroundStyle(stream.presentation.worstStaleMS > 100 ? .red : .green)
            // The frame budget, on screen. `gap` is the one that matters for
            // input latency: it is the spacing between ticks, so it counts
            // main-thread work this class never sees — SwiftUI re-evaluating
            // the view tree, chiefly. emulate+render small but gap large means
            // the cost is outside the emulator, and no amount of making the
            // emulator faster will help.
            Text(String(format: "emu %.1f  img %.1f ms",
                        stream.profile.emulateMS, stream.profile.renderMS))
            Text(String(format: "gap %.1f  max %.0f ms",
                        stream.profile.gapMS, stream.profile.worstGapMS))
            Text("late \(stream.profile.lateTicks)/120")
                .foregroundStyle(stream.profile.lateTicks > 6 ? .red : .green)
            // Finger-to-code latency, measured from the event's own timestamp.
            // This is the number the whole input investigation turns on.
            // The sample count is not decoration. Without it "touch 0 max 0"
            // reads identically whether delivery is instant or whether the
            // gesture never fired at all — opposite diagnoses.
            Text(String(format: "touch %.0f max %.0f ms n%d",
                        stream.inputLatency.lastMS,
                        stream.inputLatency.worstMS,
                        stream.inputLatency.samples))
                .foregroundStyle(stream.inputLatency.worstMS > 100 ? .red : .green)
            // Delivery and recognition are separate costs. This is the second:
            // how long SwiftUI took to turn a delivered touch into a gesture
            // callback, and therefore what dropping to a raw `touchesBegan`
            // could save.
            Text(String(format: "gest %.0f max %.0f ms n%d",
                        stream.gestureLatency.lastMS,
                        stream.gestureLatency.worstMS,
                        stream.gestureLatency.samples))
                .foregroundStyle(stream.gestureLatency.worstMS > 50 ? .red : .green)
            if !compact {
                Text("bank \(host.nes.mapper.currentPRGBank)")
                Text(String(format: "PC $%04X", host.nes.cpu.pc))
                Text("scanline \(host.nes.ppu.scanline)")
                // Audio rate and how full the queue is. Together these name the
                // fault that made the Apple TV sound like it was dragging: the
                // APU generated 44.1 kHz into hardware that wanted 48, so the
                // queue emptied every frame and the last sample was repeated.
                // A rate that is not the hardware's, or a buffer sitting near
                // zero, is that bug — visible without a Mac attached.
                Text(String(format: "audio %.0f Hz  buf %d",
                            host.nes.apu.sampleRate, host.audioBuffered))
                    .foregroundStyle(host.audioBuffered < 256 ? .red : .green)
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
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
