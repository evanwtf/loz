import SwiftUI
import NESCore

/// Loads a game's ROM from the app bundle and launches straight into it.
///
/// This is the whole app: no ROM picker, no library, no menu. Whatever goes
/// wrong is surfaced explicitly rather than as a black screen, because the most
/// likely failure — a missing or mismatched ROM — is invisible otherwise.
public struct GameLauncher<G: GameDefinition>: View {

    private let game: G.Type

    @State private var host: EmulatorHost?
    @State private var failure: String?

    public init(game: G.Type) {
        self.game = game
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
                    .task { load() }
            }
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }

    private func load() {
        guard let url = Bundle.main.url(
            forResource: G.romResourceName, withExtension: "nes")
        else {
            failure = """
                Missing ROM resource "\(G.romResourceName).nes".

                ROMs are not committed to the repository. Copy your own dump \
                into Apps/ZeldaiOS/ before building.
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
