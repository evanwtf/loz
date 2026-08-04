import Foundation
import NESCore
@testable import NESPlayer
import Testing

/// A cartridge with a battery, which the other test games deliberately lack —
/// without one `EmulatorHost` drops the save URL and the sync entirely, and
/// none of this code runs.
enum BatteryTestGame: GameDefinition {
    static let title = "Battery Test Game"
    static let romResourceName = "loz-battery-\(UUID().uuidString.prefix(8))"
    static let expectedMapper = 0
    static let expectedROMHash = ROMHash.hex(of: romImage)

    static let romImage: [UInt8] = {
        var header: [UInt8] = Array("NES\u{1A}".utf8)
        // Flags 6 bit 1 is the battery. That single bit is the difference
        // between this suite testing something and testing nothing.
        header += [2, 1, 0x02, 0x00]
        header += [UInt8](repeating: 0, count: 8)

        var prg = [UInt8](repeating: 0xEA, count: 0x8000)
        prg[0x7FFC] = 0x00
        prg[0x7FFD] = 0x80
        return header + prg + [UInt8](repeating: 0, count: 0x2000)
    }()
}

/// Telling the player their quest was written down — and, just as importantly,
/// not telling them so every three seconds.
///
/// The periodic caller runs at 3 s, but Zelda touches battery RAM only when the
/// player saves, dies and continues, or registers a name. Before this, every
/// tick wrote 8 KB to disk and pushed 8 KB to iCloud whether or not anything
/// had changed — which is a needless write forever into a 1 MB budget, and made
/// "saved" an event with no meaning.
@Suite("Battery save notices", .serialized)
@MainActor
struct SaveNoticeTests {
    private func makeHost(
        sync: SaveSync?,
        file: URL
    ) throws -> EmulatorHost {
        let host = try EmulatorHost(
            game: BatteryTestGame.self,
            romData: BatteryTestGame.romImage,
            saveURL: file,
            saveSync: sync)
        // Otherwise the host leaves snapshots in Application Support behind
        // every test; turning it off deletes them.
        host.autoResumeEnabled = false
        return host
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loz-test-\(UUID().uuidString).sav")
    }

    private func cleanUp(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    /// The behaviour the whole feature rests on.
    @Test("An unchanged cartridge is not written again, and says nothing")
    func unchangedIsSilent() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = FakeKeyValueStore()
        let host = try makeHost(sync: SaveSync(store: store, key: "b"), file: file)

        // Stands in for the three-second timer firing repeatedly with the game
        // sitting on the title screen.
        for _ in 0..<5 { host.saveBatterySave() }

        #expect(host.notices.latest == nil)
        #expect(store.storage.isEmpty)
    }

    @Test("A real save reaches iCloud and is announced")
    func changedGoesToCloud() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = FakeKeyValueStore()
        let host = try makeHost(sync: SaveSync(store: store, key: "b"), file: file)

        host.nes.cartridge.prgRAM[0] = 0x42
        host.saveBatterySave()

        #expect(host.notices.latest?.kind == .savedToCloud)
        #expect(store.storage["b"] != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The player can act on this one, which is why it is worth interrupting
    /// for: it is the difference between "my other device will have this" and
    /// "it won't".
    @Test("A save with iCloud unreachable says so rather than claiming success")
    func changedWithoutCloud() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = FakeKeyValueStore()
        store.available = false
        let host = try makeHost(sync: SaveSync(store: store, key: "b"), file: file)

        host.nes.cartridge.prgRAM[0] = 0x42
        host.saveBatterySave()

        #expect(host.notices.latest?.kind == .savedLocally)
        #expect(host.notices.latest?.isWarning == true)
        // Local persistence still happened; only the sharing did not.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// "Saved on this device" is only news when the other outcome was possible.
    @Test("A build that never asked to sync says nothing at all")
    func noSyncMeansNoNotice() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let host = try makeHost(sync: nil, file: file)

        host.nes.cartridge.prgRAM[0] = 0x42
        host.saveBatterySave()

        #expect(host.notices.latest == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Only the change is written, so a second identical save is silent")
    func secondSaveIsSilent() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let store = FakeKeyValueStore()
        let host = try makeHost(sync: SaveSync(store: store, key: "b"), file: file)

        host.nes.cartridge.prgRAM[0] = 0x42
        host.saveBatterySave()
        let first = try #require(host.notices.latest)

        host.saveBatterySave()
        #expect(host.notices.latest?.id == first.id, "a second notice was posted")
    }

    /// The case that would otherwise make a broken build look like a working
    /// one: the store says it is usable, then refuses the write.
    ///
    /// Reachable in production, not hypothetical. `UbiquitousKeyValueStore`
    /// latches `isAvailable` true on the first success, so a later
    /// `synchronize()` returning false — which is what a missing or invalid
    /// entitlement produces — arrives after the availability check has already
    /// passed.
    @Test("A refused write is reported as local, not as a successful sync")
    func refusedWriteIsNotSuccess() throws {
        let file = tempFile()
        defer { cleanUp(file) }
        let host = try makeHost(
            sync: SaveSync(store: RefusingStore(), key: "b"), file: file)

        host.nes.cartridge.prgRAM[0] = 0x42
        host.saveBatterySave()

        #expect(host.notices.latest?.kind == .savedLocally)
        #expect(host.notices.latest?.isWarning == true)
    }

    /// A toast that timed out must not take a newer one down with it.
    @Test("Clearing a stale notice leaves a newer one alone")
    func clearingIsIdentityChecked() throws {
        let stream = SaveNoticeStream()
        stream.post(.savedToCloud)
        let old = stream.latest
        stream.post(.savedLocally)

        try stream.clear(#require(old))
        #expect(stream.latest?.kind == .savedLocally)
    }

    @Test("Both notices name the game, not the storage")
    func copyIsPlain() {
        #expect(SaveNotice(kind: .savedToCloud).message == "Game saved to iCloud")
        #expect(SaveNotice(kind: .savedLocally).message
            == "Game saved on this device only")
        #expect(SaveNotice(kind: .savedToCloud).isWarning == false)
    }
}

/// Reports itself usable, then refuses every write — the shape a
/// `UbiquitousKeyValueStore` takes when availability has already latched true
/// and a later `synchronize()` fails.
private final class RefusingStore: KeyValueStore {
    var isAvailable: Bool { true }
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data, forKey key: String) { storage[key] = data }

    @discardableResult
    func synchronize() -> Bool { false }
}
