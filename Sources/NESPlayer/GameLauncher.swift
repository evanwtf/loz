import SwiftUI
import NESCore

/// Loads a game's ROM from the app bundle and launches straight into it.
///
/// This is the whole app: no ROM picker, no library, no menu. Whatever goes
/// wrong is surfaced explicitly rather than as a black screen, because the most
/// likely failure — a missing or mismatched ROM — is invisible otherwise.
public struct GameLauncher<G: GameDefinition>: View {

    private let game: G.Type
    /// Explicit ROM location. Command-line launched builds are not app bundles,
    /// so they pass a path; bundled apps leave this nil and use their resource.
    private let romURL: URL?

    @State private var host: EmulatorHost?
    @State private var failure: String?

    public init(game: G.Type, romURL: URL? = nil) {
        self.game = game
        self.romURL = romURL
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let host {
                EmulatorView(host: host)
            } else if let failure {
                failureView(failure)
            } else {
                ProgressView()
                    .tint(.white)
                    .task {
                        #if os(iOS)
                        LaunchOptions.applyRequestedOrientation()
                        #endif
                        load()
                    }
            }
        }
        // The game is a dark, full-bleed surface; a light-mode menu material
        // over it reads as a system alert intruding rather than part of the app.
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }

    private func load() {
        let bundled = Bundle.main.url(
            forResource: G.romResourceName, withExtension: "nes")

        guard let url = romURL ?? bundled else {
            failure = """
                Missing ROM "\(G.romResourceName).nes".

                ROMs are not committed to the repository. Supply your own dump \
                of a cartridge you own.
                """
            return
        }

        do {
            let data = try Data(contentsOf: url)
            host = try EmulatorHost(
                game: game,
                romData: [UInt8](data),
                saveURL: EmulatorHost.defaultSaveURL(for: G.romResourceName))
        } catch {
            failure = String(describing: error)
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text(G.title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }
}
