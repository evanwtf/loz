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

    /// Records the delivery latency of one input event.
    public func noteInputEvent(at eventTime: Date) {
        let ms = Date().timeIntervalSince(eventTime) * 1000
        // A negative or absurd reading means the clocks disagree rather than
        // that input took ten seconds; drop it instead of poisoning the worst
        // case, which is the number a diagnosis will hang on.
        guard ms >= 0, ms < 10000 else { return }
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
        didSet { isMuted ? audio.stop() : audio.start() }
    }

    private let saveURL: URL?
    private var framesSinceSaveCheck = 0

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
    public init<G: GameDefinition>(
        game _: G.Type,
        romData: [UInt8],
        saveURL: URL? = nil
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
        if !isMuted { audio.start() }
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
        audio.stop()
        persistForBackgrounding()
        Log.host.notice("stopped")
    }

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
        frames.image = FrameRenderer.image(from: nes.framebuffer)
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

    private func loadBatterySave() {
        guard let saveURL, let data = try? Data(contentsOf: saveURL) else { return }
        let bytes = [UInt8](data)
        guard bytes.count == nes.cartridge.prgRAM.count else { return }
        nes.cartridge.prgRAM = bytes
    }

    public func saveBatterySave() {
        guard let saveURL else { return }
        try? Data(nes.cartridge.prgRAM).write(to: saveURL, options: .atomic)
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
