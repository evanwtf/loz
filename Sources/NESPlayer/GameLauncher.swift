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
    /// Held back until the loading screen has been readable, so the one line
    /// explaining an empty file screen is not shown for two frames.
    @State private var revealed = false
    @State private var report: SaveReport?
    @State private var secondsLeft = 0
    @State private var skipped = false

    /// Whether to show the iCloud loading screen at all. Toggled in the game
    /// menu; a player who trusts their sync should not have to look at it.
    @AppStorage("nesCloudScreen") private var showCloudScreen = true

    /// How long the loading screen stays up in total.
    private static var screenSeconds: Int { 10 }
    /// The least time the *outcome* stays readable, however long the check
    /// took. Without this a slow check would eat the whole ten seconds and the
    /// player would never see the answer the screen exists to give.
    private static var minimumReadable: TimeInterval { 3 }
    /// How long to let iCloud hand over another device's saves before giving
    /// up. Only ever spent on a device that has an account and no local copy —
    /// see `CloudGate`.
    private static var gateTimeout: Duration { .seconds(4) }

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
                Group {
                    if showCloudScreen {
                        cloudLoadingScreen
                    } else {
                        // Still a wait, just not an explained one.
                        ProgressView().tint(.white)
                    }
                }
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

    /// The iCloud loading screen: what iCloud is doing, and what it means.
    ///
    /// It exists because the alternative was worse than slow — the game used to
    /// read iCloud the instant it launched, before the store had received
    /// anything, so a device syncing perfectly showed an empty file screen and
    /// only worked on the *second* launch. Now the wait is visible and the
    /// outcome is explained.
    private var cloudLoadingScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: report?.symbol ?? "icloud")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(report?.isWarning == true ? .yellow : .white)

            Text(report?.headline ?? "Checking iCloud for saved games…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(report?.isWarning == true ? .yellow : .white)

            Text(report?.detail
                ?? "Your saved games are shared between your devices.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                // Wide enough that a tvOS canvas (1920 pt) does not wrap two
                // short sentences into four lines; narrower than any phone, so
                // on iOS the padding still decides.
                .frame(maxWidth: 720)
                // Reserves room for the longest message from the start, so
                // arriving at an answer does not shove the stack around.
                .frame(minHeight: 64, alignment: .top)

            // Only when something actually came from iCloud. A device with
            // nothing stored has no date to show, and inventing one — "never",
            // "—" — would just be noise on a screen that is already saying so.
            if let savedAt = report?.savedAt() {
                Label(savedAt, systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

            if report == nil {
                ProgressView().tint(.white)
            } else {
                VStack(spacing: 4) {
                    Text("Starting \(G.title) in \(secondsLeft)…")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Press any button to skip")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(28)
        .skipOnAnyInput { skipped = true }
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
        let opened = Date()

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

        guard showCloudScreen else {
            revealed = true
            return
        }
        await holdLoadingScreen(since: opened)
        revealed = true
    }

    /// Keeps the loading screen up, counting down, until it has been up for
    /// `screenSeconds` — or until the player skips.
    ///
    /// The deadline is the later of "ten seconds since launch" and "three
    /// seconds since there was an answer to show". A check that took eight
    /// seconds would otherwise leave the outcome on screen for two, which is
    /// long enough to notice and not long enough to read.
    private func holdLoadingScreen(since opened: Date) async {
        let deadline = max(
            opened.addingTimeInterval(TimeInterval(Self.screenSeconds)),
            Date().addingTimeInterval(Self.minimumReadable))

        while !skipped {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            // Rounded up so the last whole second reads "1" rather than "0".
            secondsLeft = Int(remaining.rounded(.up))
            // Fine-grained relative to the second it displays, so the number
            // changes when the clock does rather than up to a second late.
            try? await Task.sleep(for: .milliseconds(100))
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
