import Combine
import CoreGraphics
import Foundation
import NESCore
import QuartzCore

#if canImport(AppKit)
    import AppKit
#endif

/// Drives one game: clocks the emulator at display refresh, publishes frames,
/// routes input, and persists battery-backed saves.
///
/// Runs entirely on the main actor. The emulator has roughly 14x real-time
/// headroom, so there is no reason to introduce a second thread and the data
/// races that come with it.
@MainActor
public final class EmulatorHost: ObservableObject {
    public let nes: NES
    public let title: String
    /// Identifies the exact dump in use, so save states cannot be loaded into
    /// a different ROM.
    public let romHash: String
    /// Bundle resource name, used to namespace saves per game.
    public let gameName: String

    /// The picture, published on its own object.
    ///
    /// This is deliberately *not* `@Published` on the host. Anything observing
    /// an `ObservableObject` is invalidated by any of its published properties,
    /// so a frame arriving 60 times a second rebuilt the whole view tree 60
    /// times a second — including every control and every `DragGesture`
    /// attached to one. SwiftUI replaced the gesture recognisers faster than a
    /// touch could be recognised, and presses were simply lost: the callout
    /// pins never appeared, and the game was unplayable while the frame clock
    /// reported a flawless 60 fps with no late ticks.
    ///
    /// Giving the image its own object confines that invalidation to the view
    /// that draws it.
    public let frames = FrameStream()

    /// Most recent frame. Reading this does not subscribe the reader to
    /// per-frame updates; observe `frames` for that.
    public var frame: CGImage? { frames.image }

    @Published public var isPaused = false

    /// Frame timings and input latency, on their own object for the same
    /// reason as `frames`.
    ///
    /// `inputLatency` is the sharp case: it updates on *every* drag event, so
    /// leaving it on the host would rebuild the control tree — and with it the
    /// gesture recognisers — continuously while a finger is down. The
    /// instrument would have caused the fault it was added to measure.
    public let diagnostics = DiagnosticsStream()

    public var framesPerSecond: Double { diagnostics.framesPerSecond }

    /// Records an absolute touch-delivery latency, in milliseconds.
    ///
    /// Fed by `TouchLatencyProbe` from `UITouch.timestamp`, which has a
    /// documented epoch. The earlier route through `DragGesture.Value.time`
    /// did not, and produced readings that alternated between 0 ms and 757 ms
    /// on a device that was otherwise healthy — a shape with no physical
    /// explanation, and a reminder that an instrument reporting a dramatic
    /// number is not the same as a discovery.
    /// When the window probe last saw a touch begin, in `systemUptime`.
    /// Used to time SwiftUI's gesture arbitration separately from delivery.
    private var lastTouchBeganUptime: Double = 0

    /// How long SwiftUI took to turn a delivered touch into a gesture callback.
    ///
    /// Delivery and recognition are different costs and only the first was
    /// being measured. The window probe fails itself immediately, so it sees a
    /// touch at the earliest possible moment; a `DragGesture` has to go through
    /// arbitration first. The difference is what a raw `touchesBegan` in a
    /// `UIViewRepresentable` would save, and it is worth knowing before
    /// rewriting the controls to find out.
    public func noteGestureHandled() {
        guard lastTouchBeganUptime > 0 else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - lastTouchBeganUptime) * 1000
        // Consume the timestamp. `onChanged` fires continuously while a finger
        // is down, so without this every callback re-measures against the
        // original touch and the figure becomes the hold duration: a two-second
        // press on the d-pad reported 1631 ms of "recognition latency". One
        // sample per touch-down, and only the first, is the actual quantity.
        lastTouchBeganUptime = 0
        guard ms >= 0, ms < 5000 else { return }
        let previous = diagnostics.gestureLatency
        diagnostics.gestureLatency = InputLatency(
            lastMS: ms,
            worstMS: max(previous.worstMS, ms),
            samples: previous.samples + 1)
    }

    public func noteTouchLatency(_ ms: Double) {
        lastTouchBeganUptime = ProcessInfo.processInfo.systemUptime
        let previous = diagnostics.inputLatency
        diagnostics.inputLatency = InputLatency(
            lastMS: ms,
            worstMS: max(previous.worstMS, ms),
            samples: previous.samples + 1)
        if ms > 100 {
            Log.ui.notice("input delivered \(ms, format: .fixed(precision: 0), privacy: .public) ms late")
        }
    }

    /// Clears the worst-case reading so a fix can be judged on fresh numbers.
    public func resetInputLatency() {
        diagnostics.inputLatency = InputLatency()
    }

    /// Multiplies emulation speed; held down for fast-forward.
    @Published public var speedMultiplier: Int = 1

    private var clock: FrameClock?
    private var lastFPSSample = CFAbsoluteTimeGetCurrent()
    private var framesSinceSample = 0
    private var lastPresentedCount = 0

    /// Frame-budget accounting. Always on: two clock reads per frame cost
    /// nothing measurable, and gating it behind a launch option meant the one
    /// run that reproduced a bug was the run with no numbers. Chasing input
    /// latency without this has now cost several rounds of guessing.
    private var profileEmulation: Double = 0
    private var profileRender: Double = 0
    private var profileFrames = 0
    /// Gap between consecutive ticks. This is the measurement that separates
    /// the two candidate explanations for late input: work *inside* the tick
    /// (emulate/render, below) versus work the main thread does after it
    /// returns — SwiftUI re-evaluating the view tree, which no timer around
    /// `tick()` can see. If the gaps run long while emulate+render stay
    /// small, the cost is outside this class.
    private var lastTickStart: Double = 0
    private var profileGap: Double = 0
    private var profileWorstGap: Double = 0
    private var profileLateTicks = 0

    private let audio: AudioOutput
    /// Muting stops audio reaching the speaker but keeps the APU running, so
    /// unmuting resumes mid-phrase rather than restarting a note.
    @Published public var isMuted = false {
        didSet { syncAudioToRunState() }
    }

    private let saveURL: URL?
    private var framesSinceSaveCheck = 0

    /// Syncs the cartridge battery save across devices, when iCloud is
    /// available. Nil disables syncing entirely and leaves saves local.
    private let saveSync: SaveSync?

    private let autoResumeURL: URL?
    private var framesSinceAutoResume = 0

    /// Whether the game snapshots itself so it can pick up exactly where it was
    /// left. On by default: on a phone, sessions are short and interrupted, and
    /// Zelda's own save only records progress at coarse checkpoints.
    @Published public var autoResumeEnabled = true {
        didSet {
            if !autoResumeEnabled, let autoResumeURL {
                AutoResume.clear(at: autoResumeURL)
            }
        }
    }

    // MARK: Lifecycle

    /// - Parameters:
    ///   - game: the single game this app plays.
    ///   - romData: raw iNES image, validated against the game's expected hash.
    ///   - saveURL: where battery-backed RAM is persisted, if the cart has any.
    ///   - saveSync: cross-device save syncing. Defaults to iCloud's key-value
    ///     store; pass nil for local-only saves.
    public init<G: GameDefinition>(
        game _: G.Type,
        romData: [UInt8],
        saveURL: URL? = nil,
        saveSync: SaveSync? = SaveSync(
            store: UbiquitousKeyValueStore(), key: "battery-save")
    ) throws {
        let cartridge = try Cartridge(data: romData)
        try G.validate(romData: romData, cartridge: cartridge)

        let sampleRate = 44100.0
        audio = AudioOutput(sampleRate: sampleRate)
        nes = try NES(cartridge: cartridge, sampleRate: sampleRate)
        nes.nativeRoutines = G.nativeRoutines
        title = G.title
        romHash = G.expectedROMHash
        gameName = G.romResourceName
        self.saveURL = cartridge.hasBattery ? saveURL : nil
        self.saveSync = cartridge.hasBattery ? saveSync : nil
        autoResumeURL = AutoResume.url(for: G.romResourceName)
        isMuted = LaunchOptions.startMuted

        Log.host.notice("""
        \(BuildInfo.summary, privacy: .public) — \(G.title, privacy: .public), \
        mapper \(cartridge.mapperNumber, privacy: .public), \
        \(romData.count, privacy: .public) bytes, \
        battery \(cartridge.hasBattery, privacy: .public)
        """)

        loadBatterySave()
        restoreAutoResume()
        renderCurrentFrame()
    }

    // MARK: Auto-resume

    /// Picks up where the player left off, if a snapshot is waiting.
    ///
    /// Silent by design — the game simply is where it was. Any failure falls
    /// through to a normal boot rather than surfacing an error, because a
    /// stale or unreadable snapshot is not something a player can act on.
    @discardableResult
    public func restoreAutoResume() -> Bool {
        guard autoResumeEnabled,
              let autoResumeURL,
              let state = AutoResume.read(from: autoResumeURL)
        else { return false }

        do {
            // The hash check refuses a snapshot from a different dump, which
            // would otherwise load as convincing nonsense.
            try nes.restoreState(state, romHash: romHash)
            renderCurrentFrame()
            return true
        } catch {
            Log.state.notice("auto-resume: ignoring snapshot: \(error.localizedDescription, privacy: .public)")
            AutoResume.clear(at: autoResumeURL)
            return false
        }
    }

    /// Snapshots the machine. Call when backgrounding, and periodically.
    public func saveAutoResume() {
        guard autoResumeEnabled, let autoResumeURL else { return }
        // Capturing is a cheap array copy on the main actor; encoding and
        // writing happen off it so the frame loop never stalls on I/O.
        AutoResume.write(nes.captureState(romHash: romHash), to: autoResumeURL)
    }

    /// Everything that must be persisted before the app may be suspended or
    /// killed: cartridge battery RAM and the resume snapshot.
    public func persistForBackgrounding() {
        saveBatterySave()
        saveAutoResume()
    }

    public func start() {
        guard clock == nil else { return }
        let clock = FrameClock { [weak self] in self?.tick() }
        clock.start()
        self.clock = clock
        syncAudioToRunState()
        // Values are hoisted into locals before every log call in this type.
        // A Logger message is an autoclosure, so referring to a property
        // directly needs an explicit `self.` — which the formatter's
        // `--self remove` rule then strips, breaking the build. Locals sidestep
        // the argument entirely and read better besides.
        let muted = isMuted
        Log.host.notice("started (muted \(muted, privacy: .public))")
    }

    public func stop() {
        clock?.stop()
        clock = nil
        syncAudioToRunState()
        persistForBackgrounding()
        Log.host.notice("stopped")
    }

    /// Opens or closes the audio device to match whether the host is actually
    /// running and unmuted.
    ///
    /// Audio follows the *run state*, not the mute flag on its own. That
    /// distinction is the whole point: a host that has never been started must
    /// never reach the speaker, and before this it always did.
    ///
    /// `isMuted` is `@Published`, so assigning it in `init` goes through the
    /// property wrapper's setter rather than initialising storage directly —
    /// which means `didSet` *fires during initialisation*, unlike a plain
    /// stored property. The old observer started the engine on any unmuted
    /// assignment, so simply constructing an `EmulatorHost` opened the audio
    /// device. Every `swift test` run played Zelda out loud (twelve engine
    /// starts across the eleven hosts the suite builds), and so did
    /// `zeldamac --selftest`, neither of which has a window or a listener.
    ///
    /// Gating on `clock` rather than on a "headless" flag avoids having to
    /// detect the test runner: nothing that never calls `start()` can make a
    /// sound, by construction.
    private func syncAudioToRunState() {
        if clock != nil, !isMuted {
            audio.start()
        } else {
            audio.stop()
        }
    }

    /// Whether the audio device is currently open. Exposed so a test can assert
    /// that a host which was never started stays silent.
    public var isAudioRunning: Bool { audio.isRunning }

    // MARK: Frame loop

    /// Runs one frame. Exposed so headless self-tests can drive the host
    /// without a display attached.
    public func tick() {
        guard !isPaused else { return }

        // Where the frame budget actually goes. "Input takes half a second to
        // register" has several possible causes with completely different
        // fixes — emulation too slow, the render path too slow, the clock not
        // firing, or the main thread busy elsewhere — and guessing between
        // them from the outside wastes far more time than measuring.
        let tickStart = CFAbsoluteTimeGetCurrent()
        if lastTickStart > 0 {
            let gap = tickStart - lastTickStart
            profileGap += gap
            profileWorstGap = max(profileWorstGap, gap)
            // Anything past 20 ms missed a 60 Hz refresh.
            if gap > 0.020 { profileLateTicks += 1 }
        }
        lastTickStart = tickStart

        for _ in 0..<max(1, speedMultiplier) {
            nes.stepFrame()
            drainAudio()
        }
        let afterEmulation = CFAbsoluteTimeGetCurrent()
        renderCurrentFrame()

        let afterRender = CFAbsoluteTimeGetCurrent()
        profileEmulation += afterEmulation - tickStart
        profileRender += afterRender - afterEmulation
        profileFrames += 1
        if profileFrames >= 120 {
            let n = Double(profileFrames)
            let fps = framesPerSecond
            let emulateMS = profileEmulation / n * 1000
            let renderMS = profileRender / n * 1000
            let gapMS = profileGap / n * 1000
            let worstMS = profileWorstGap * 1000
            let late = profileLateTicks
            var snapshot = FrameProfile()
            snapshot.emulateMS = emulateMS
            snapshot.renderMS = renderMS
            snapshot.gapMS = gapMS
            snapshot.worstGapMS = worstMS
            snapshot.lateTicks = late
            diagnostics.profile = snapshot
            Log.clock.notice("""
            perf: \(fps, format: .fixed(precision: 1), privacy: .public) fps  \
            emulate \(emulateMS, format: .fixed(precision: 2), privacy: .public) ms  \
            render \(renderMS, format: .fixed(precision: 2), privacy: .public) ms  \
            gap avg \(gapMS, format: .fixed(precision: 2), privacy: .public) ms \
            worst \(worstMS, format: .fixed(precision: 1), privacy: .public) ms  \
            late \(late, privacy: .public)/120  budget 16.67 ms
            """)
            profileEmulation = 0
            profileRender = 0
            profileFrames = 0
            profileGap = 0
            profileWorstGap = 0
            profileLateTicks = 0
        }

        framesSinceSample += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFPSSample
        if elapsed >= 0.5 {
            diagnostics.framesPerSecond = Double(framesSinceSample) / elapsed
            framesSinceSample = 0
            lastFPSSample = now

            // Sample what the display actually took, alongside what was
            // emulated. Emulating a frame is not the same as showing one.
            var shown = Presentation()
            shown.shownPerSecond =
                Double(frames.presented - lastPresentedCount) / elapsed
            shown.staleMS = frames.lastStaleMS
            shown.worstStaleMS = frames.worstStaleMS
            diagnostics.presentation = shown
            lastPresentedCount = frames.presented
        }

        // Flush the save file periodically rather than on every write, so a
        // crash costs at most a couple of seconds of progress.
        framesSinceSaveCheck += 1
        if framesSinceSaveCheck >= 180 {
            framesSinceSaveCheck = 0
            saveBatterySave()
        }

        // Snapshot periodically as a backstop. Backgrounding writes one anyway;
        // this covers the cases where no notification arrives — an
        // out-of-memory kill, a crash, or a force quit.
        framesSinceAutoResume += 1
        if framesSinceAutoResume >= AutoResume.intervalFrames {
            framesSinceAutoResume = 0
            saveAutoResume()
        }
    }

    private func renderCurrentFrame() {
        frames.publish(FrameRenderer.image(from: nes.framebuffer))
    }

    /// Total samples the APU has produced since launch. Diagnostic: if this is
    /// not advancing at roughly the sample rate, audio is starving.
    public private(set) var totalAudioSamples = 0

    private func drainAudio() {
        let ready = nes.apu.availableSamples
        guard ready > 0 else { return }
        let samples = nes.apu.drain(count: ready)
        totalAudioSamples += samples.count
        // While fast-forwarding, the APU generates several frames' worth of
        // audio per display frame. Playing it all would sound like chipmunks
        // and overflow the queue, so drop it and keep the picture responsive.
        guard !isMuted, speedMultiplier == 1 else { return }
        audio.enqueue(samples)
    }

    // MARK: Input

    public func setButton(_ button: NESButton, pressed: Bool, player: Int = 1) {
        let pad = player == 2 ? nes.controller2 : nes.controller1
        pad.set(button, pressed: pressed)
    }

    public func releaseAllButtons() {
        nes.controller1.releaseAll()
        nes.controller2.releaseAll()
    }

    public func reset() {
        nes.reset()
        refreshFrameAfterStateChange()
    }

    /// Re-renders immediately after the machine state is replaced, so the
    /// picture updates even while paused.
    public func refreshFrameAfterStateChange() {
        renderCurrentFrame()
    }

    // MARK: Battery save

    /// Loads the quest, preferring whichever copy is newer — this device's or
    /// the one in iCloud.
    ///
    /// The local file is always written, even when the cloud copy wins, so the
    /// device is never left depending on the network to know where the player
    /// got to.
    private func loadBatterySave() {
        let expected = nes.cartridge.prgRAM.count

        var local: SaveSync.Version?
        if let saveURL,
           let data = try? Data(contentsOf: saveURL),
           let modified = (try? FileManager.default.attributesOfItem(atPath: saveURL.path))?[
               .modificationDate] as? Date
        {
            local = SaveSync.Version(data: [UInt8](data), modified: modified)
        }

        let remote = saveSync?.read()
        let resolution = SaveSync.resolve(
            local: local, remote: remote, expectedSize: expected)

        switch resolution {
        case .noSave:
            return
        case .useLocal, .noChange:
            if let local { nes.cartridge.prgRAM = local.data }
            // Seed the cloud from a device that has progress and it does not.
            if remote == nil, let local, !local.data.allSatisfy({ $0 == 0 }) {
                saveSync?.write(local.data, modified: local.modified)
            }
        case .useRemote:
            guard let remote else { return }
            nes.cartridge.prgRAM = remote.data
            if let saveURL {
                try? Data(remote.data).write(to: saveURL, options: .atomic)
            }
        }

        let verdict = String(describing: resolution)
        Log.state.notice("battery save: \(verdict, privacy: .public)")
    }

    public func saveBatterySave() {
        let bytes = nes.cartridge.prgRAM
        guard let saveURL else { return }
        try? Data(bytes).write(to: saveURL, options: .atomic)

        // Pushed on every save rather than only on backgrounding: a save is
        // already a deliberate, infrequent act — the game writes battery RAM
        // when the player saves or dies, not per frame.
        saveSync?.write(bytes, modified: Date())
    }

    /// Default save location inside the app's Application Support directory.
    public static func defaultSaveURL(for resourceName: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }

        let directory = base.appendingPathComponent("loz", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(resourceName).sav")
    }
}
