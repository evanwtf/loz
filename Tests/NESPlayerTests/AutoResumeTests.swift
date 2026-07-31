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

/// Auto-resume is what makes this playable in the gaps of a day: the app should
/// come back exactly where it was, without the player having chosen to save.
@Suite("Auto-resume")
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

        // The production write is detached; give it a moment to land.
        let deadline = Date().addingTimeInterval(2)
        let url = try #require(AutoResume.url(for: TestGame.romResourceName))
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

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
