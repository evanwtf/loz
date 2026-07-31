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

    @Published public private(set) var frame: CGImage?
    @Published public private(set) var framesPerSecond: Double = 0
    @Published public var isPaused = false

    /// Multiplies emulation speed; held down for fast-forward.
    @Published public var speedMultiplier: Int = 1

    private var clock: FrameClock?
    private var lastFPSSample = CFAbsoluteTimeGetCurrent()
    private var framesSinceSample = 0

    private let audio: AudioOutput
    /// Muting stops audio reaching the speaker but keeps the APU running, so
    /// unmuting resumes mid-phrase rather than restarting a note.
    @Published public var isMuted = false {
        didSet { isMuted ? audio.stop() : audio.start() }
    }

    private let saveURL: URL?
    private var framesSinceSaveCheck = 0

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
        isMuted = LaunchOptions.startMuted

        loadBatterySave()
        renderCurrentFrame()
    }

    public func start() {
        guard clock == nil else { return }
        let clock = FrameClock { [weak self] in self?.tick() }
        clock.start()
        self.clock = clock
        if !isMuted { audio.start() }
    }

    public func stop() {
        clock?.stop()
        clock = nil
        audio.stop()
        saveBatterySave()
    }

    // MARK: Frame loop

    /// Runs one frame. Exposed so headless self-tests can drive the host
    /// without a display attached.
    public func tick() {
        guard !isPaused else { return }

        for _ in 0..<max(1, speedMultiplier) {
            nes.stepFrame()
            drainAudio()
        }
        renderCurrentFrame()

        framesSinceSample += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFPSSample
        if elapsed >= 0.5 {
            framesPerSecond = Double(framesSinceSample) / elapsed
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
    }

    private func renderCurrentFrame() {
        frame = FrameRenderer.image(from: nes.framebuffer)
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
