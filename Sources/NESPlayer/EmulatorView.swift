import SwiftUI
import NESCore

/// The game screen: a nearest-neighbour scaled framebuffer, letterboxed.
public struct GameScreen: View {
    public let image: CGImage?

    public init(image: CGImage?) {
        self.image = image
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .interpolation(.none)     // never smooth pixel art
                        .antialiased(false)
                        .resizable()
                        // The NES output a 256x240 buffer to a 4:3 screen, so
                        // pixels were slightly tall. Matching that is what makes
                        // the picture look right rather than subtly squashed.
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Full player UI: screen, platform-appropriate controls, and an optional
/// diagnostics overlay.
public struct EmulatorView: View {
    @ObservedObject private var host: EmulatorHost
    @State private var showDiagnostics = false

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
        VStack(spacing: 0) {
            GameScreen(image: host.frame)
                .frame(maxHeight: .infinity)
            TouchControls(host: host)
                .frame(height: 260)
        }
        #else
        // macOS and tvOS drive input from keyboard or a game controller, so the
        // screen gets the whole window.
        GameScreen(image: host.frame)
        #endif
    }

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
