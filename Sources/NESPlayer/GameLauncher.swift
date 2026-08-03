import NESCore
import SwiftUI

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
    /// Held back until the interstitial has been readable for a moment, so the
    /// one line explaining an empty file screen is not shown for two frames.
    @State private var revealed = false
    @State private var report: SaveReport?

    /// How long to let iCloud hand over another device's saves before giving
    /// up. Only ever spent on a device that has an account and no local copy —
    /// see `CloudGate`.
    private static var gateTimeout: Duration { .seconds(4) }
    /// How long the outcome stays up once there is something to say.
    private static var revealDelay: Duration { .milliseconds(900) }

    public init(game: G.Type, romURL: URL? = nil) {
        self.game = game
        self.romURL = romURL
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let host, revealed {
                EmulatorView(host: host)
            } else if let failure {
                failureView(failure)
            } else {
                interstitial
                    .task {
                        #if os(iOS)
                            LaunchOptions.applyRequestedOrientation()
                        #endif
                        await load()
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

    /// The launch screen: title, spinner, and what iCloud is doing.
    ///
    /// It exists because the alternative was worse than slow — the game used to
    /// read iCloud the instant it launched, before the store had received
    /// anything, so a device syncing perfectly showed an empty file screen and
    /// only worked on the *second* launch. Now the wait is visible and the
    /// outcome is stated.
    private var interstitial: some View {
        VStack(spacing: 14) {
            Text(G.title)
                .font(.headline)
                .foregroundStyle(.white)
            ProgressView()
                .tint(.white)
            Text(report?.summary ?? "Checking iCloud…")
                .font(.footnote)
                .foregroundStyle(
                    report?.isWarning == true ? .yellow : .white.opacity(0.7))
                .multilineTextAlignment(.center)
                // Reserves the line's height from the start, so arriving at an
                // answer does not shift the whole stack.
                .frame(minHeight: 20)
        }
        .padding(28)
    }

    private func load() async {
        // Prefer a ROM compiled into the binary: no file to locate, no bundle
        // resource, no way for this to fail at launch.
        if let embedded = G.embeddedROM, !embedded.isEmpty {
            await start(with: embedded)
            return
        }

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
            let romData = try Data(contentsOf: url)
            await start(with: [UInt8](romData))
        } catch {
            failure = String(describing: error)
        }
    }

    private func start(with romData: [UInt8]) async {
        // The app is where iCloud gets opted into; a bare host stays local.
        let cloud = EmulatorHost.cloudSyncing()

        // Before the host reads anything. The store answers from a local cache
        // and another device's save arrives after, so reading first is what
        // produced an empty file screen on a device that was syncing fine.
        let gate = await CloudGate(store: cloud.store)
            .wait(forKey: cloud.batteryKey, timeout: Self.gateTimeout)
        Log.state.notice("cloud gate: \(String(describing: gate), privacy: .public)")

        do {
            let host = try EmulatorHost(
                game: game,
                romData: romData,
                saveURL: EmulatorHost.defaultSaveURL(for: G.romResourceName),
                saveSync: cloud.save,
                snapshotSync: cloud.snapshot,
                cloudGate: gate)
            report = host.saveReport
            self.host = host
        } catch {
            failure = String(describing: error)
            return
        }

        // Only worth holding the screen if something was actually said. A
        // launch that never waited should not acquire a delay it did not have.
        if gate.waited || report?.isWarning == true {
            try? await Task.sleep(for: Self.revealDelay)
        }
        revealed = true
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
