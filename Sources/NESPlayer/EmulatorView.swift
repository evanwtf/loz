import SwiftUI
import NESCore

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
    @ObservedObject private var host: EmulatorHost
    @State private var showDiagnostics = LaunchOptions.showDiagnostics

    public init(host: EmulatorHost) {
        self.host = host
    }

    public var body: some View {
        content
            .background(Color.black)
            .ignoresSafeArea(edges: .bottom)
            .onAppear { host.start() }
            .onDisappear { host.stop() }
            .overlay(alignment: .topLeading) {
                if showDiagnostics { diagnostics }
            }
            .modifier(KeyboardControls(host: host, showDiagnostics: $showDiagnostics))
            .modifier(GameControllerSupport(host: host))
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
        // screen gets the whole window.
        GameScreen(image: host.frame)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }
    #endif

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.0f fps", host.framesPerSecond))
            Text("bank \(host.nes.mapper.currentPRGBank)")
            Text(String(format: "PC $%04X", host.nes.cpu.pc))
            Text("scanline \(host.nes.ppu.scanline)")
            if host.speedMultiplier > 1 {
                Text("\(host.speedMultiplier)x").foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}
