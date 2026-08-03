import Foundation
import NESCore
@testable import NESPlayer
import Testing

/// A synthetic cartridge, so these tests need no real ROM.
enum TestGame: GameDefinition {
    static let title = "Test Game"
    /// Unique per run so parallel or repeated runs cannot collide on the
    /// snapshot file in Application Support.
    static let romResourceName = "loz-test-\(UUID().uuidString.prefix(8))"
    static let expectedMapper = 0
    static let expectedROMHash = ROMHash.hex(of: romImage)

    /// 32KB NROM image running `INC $00; JMP $8000` so state actually changes
    /// as it runs — a snapshot of a static machine proves nothing.
    static let romImage: [UInt8] = {
        var header: [UInt8] = Array("NES\u{1A}".utf8)
        header += [2, 1, 0x00, 0x00]
        header += [UInt8](repeating: 0, count: 8)

        var prg = [UInt8](repeating: 0xEA, count: 0x8000)
        prg[0x0000] = 0xE6; prg[0x0001] = 0x00          // INC $00
        prg[0x0002] = 0x4C; prg[0x0003] = 0x00; prg[0x0004] = 0x80
        prg[0x7FFC] = 0x00; prg[0x7FFD] = 0x80          // reset -> $8000

        let chr = [UInt8](repeating: 0, count: 0x2000)
        return header + prg + chr
    }()
}

/// The same cartridge under a second name, for suites that build a host but do
/// not care about snapshots.
///
/// Sharing one name is what made this suite flaky. `EmulatorHost` derives the
/// auto-resume path from `romResourceName`, so one name means one file in
/// Application Support — and suites run in **parallel**. `SilentByDefaultTests`
/// constructing a host would create and clear that file underneath the tests
/// here, which failed about half the time with a snapshot that had vanished
/// between being written and being read.
///
/// The existing per-run UUID only ever guarded against *separate processes*
/// colliding, which was never the problem.
enum SilentTestGame: GameDefinition {
    static let title = "Silent Test Game"
    static let romResourceName = "loz-silent-\(UUID().uuidString.prefix(8))"
    static let expectedMapper = 0
    static let expectedROMHash = ROMHash.hex(of: TestGame.romImage)
}

/// Auto-resume is what makes this playable in the gaps of a day: the app should
/// come back exactly where it was, without the player having chosen to save.
///
/// Serialised because every test here shares one snapshot file: some write it,
/// `bootsCleanWithoutSnapshot` deletes it first thing, and in parallel that
/// deletion lands between another test writing the file and reading it back.
@Suite("Auto-resume", .serialized)
@MainActor
struct AutoResumeTests {
    private func makeHost() throws -> EmulatorHost {
        try EmulatorHost(game: TestGame.self, romData: TestGame.romImage)
    }

    private func cleanUp() {
        if let url = AutoResume.url(for: TestGame.romResourceName) {
            AutoResume.clear(at: url)
        }
    }

    @Test("A snapshot round-trips through disk")
    func snapshotRoundTrip() throws {
        defer { cleanUp() }
        guard let url = AutoResume.url(for: TestGame.romResourceName) else {
            Issue.record("no Application Support directory")
            return
        }

        let host = try makeHost()
        for _ in 0..<30 { host.tick() }
        let expectedCycles = host.nes.cycles

        // Write synchronously here; the production path encodes off the main
        // actor, which a test cannot deterministically await.
        let state = host.nes.captureState(romHash: TestGame.expectedROMHash)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)

        let restored = try #require(AutoResume.read(from: url))
        #expect(restored.cycles == expectedCycles)
        #expect(restored.romHash == TestGame.expectedROMHash)
    }

    @Test("A fresh host picks up where the previous one stopped")
    func resumesWhereItStopped() throws {
        defer { cleanUp() }

        let first = try makeHost()
        for _ in 0..<45 { first.tick() }
        let cyclesBefore = first.nes.cycles
        let ramBefore = first.nes.ram
        first.saveAutoResume()

        // The production write is detached at *utility* priority, so under load
        // it can be starved for a long time while the rest of the suite runs.
        // The deadline is a safety net against hanging, not a budget: the loop
        // exits the moment the file appears, so a generous limit costs nothing
        // on a quiet machine and is the difference between a reliable test and
        // one that fails whenever CI is busy.
        //
        // Two seconds here failed roughly one run in ten, and only ever on runs
        // that took four times as long as usual — which is the tell that this is
        // scheduling latency rather than a race over the file itself. The write
        // is atomic, so the file existing means the file is complete.
        let deadline = Date().addingTimeInterval(30)
        let url = try #require(AutoResume.url(for: TestGame.romResourceName))
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(FileManager.default.fileExists(atPath: url.path),
                "the snapshot never landed; the assertions below would blame restore")

        // A brand new host must land in the same place, not at power-on.
        let second = try makeHost()
        #expect(second.nes.cycles == cyclesBefore)
        #expect(second.nes.ram == ramBefore)
    }

    @Test("Without a snapshot the game boots normally")
    func bootsCleanWithoutSnapshot() throws {
        cleanUp()
        defer { cleanUp() }

        let host = try makeHost()
        #expect(host.nes.cycles == 0)
        #expect(!host.restoreAutoResume())
    }

    /// A snapshot from a different dump would restore as convincing nonsense,
    /// so it must be refused rather than trusted.
    @Test("A snapshot from a different ROM is refused and discarded")
    func refusesForeignSnapshot() throws {
        defer { cleanUp() }
        let url = try #require(AutoResume.url(for: TestGame.romResourceName))

        let host = try makeHost()
        for _ in 0..<20 { host.tick() }
        var state = host.nes.captureState(romHash: "not-this-rom")
        state.romHash = "not-this-rom"
        try JSONEncoder().encode(state).write(to: url, options: .atomic)

        let fresh = try makeHost()
        #expect(fresh.nes.cycles == 0, "must not restore a foreign snapshot")
        // The bad snapshot is cleared so it cannot be retried forever.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Corrupt snapshots are ignored rather than crashing")
    func ignoresCorruptSnapshot() throws {
        defer { cleanUp() }
        let url = try #require(AutoResume.url(for: TestGame.romResourceName))
        try Data("this is not a save state".utf8).write(to: url)

        let host = try makeHost()
        #expect(host.nes.cycles == 0)
    }

    @Test("Turning auto-resume off deletes the snapshot")
    func disablingClearsSnapshot() throws {
        defer { cleanUp() }
        let url = try #require(AutoResume.url(for: TestGame.romResourceName))

        let host = try makeHost()
        for _ in 0..<20 { host.tick() }
        try JSONEncoder().encode(
            host.nes.captureState(romHash: TestGame.expectedROMHash))
            .write(to: url, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: url.path))

        host.autoResumeEnabled = false
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The periodic interval is frequent enough to bound what is lost")
    func intervalIsReasonable() {
        // Backgrounding writes a snapshot anyway; this only covers kills and
        // crashes. Bounded at roughly half a minute of lost play.
        #expect(AutoResume.intervalFrames <= 30 * 60)
        #expect(AutoResume.intervalFrames >= 5 * 60)
    }
}
