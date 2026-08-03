import Foundation
@testable import NESPlayer
import Testing

/// Deciding whether the local battery save or the synced one wins.
///
/// This is the whole of the risk in syncing saves. The transport is a solved
/// problem; choosing wrongly between two versions of a quest silently deletes
/// somebody's progress, and it does it quietly — the game just starts an hour
/// earlier than it should.
///
/// Every case here is stated as a scenario rather than a truth table, because
/// the failure that matters is "which dungeon did I lose".
@Suite("Save sync resolution")
struct SaveSyncTests {
    private let eightK = [UInt8](repeating: 0, count: 0x2000)

    private func save(_ marker: UInt8) -> [UInt8] {
        var bytes = eightK
        bytes[0] = marker
        return bytes
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    @Test("With nothing anywhere, there is nothing to load")
    func nothingAnywhere() {
        #expect(SaveSync.resolve(local: nil, remote: nil) == .noSave)
    }

    @Test("A local save and no cloud save keeps the local one")
    func localOnly() {
        let local = SaveSync.Version(data: save(1), modified: date(0))
        #expect(SaveSync.resolve(local: local, remote: nil) == .useLocal)
    }

    /// The case that makes a new device useful: nothing here, a quest in the
    /// cloud.
    @Test("A cloud save and no local save adopts the cloud one")
    func remoteOnly() {
        let remote = SaveSync.Version(data: save(2), modified: date(0))
        #expect(SaveSync.resolve(local: nil, remote: remote) == .useRemote)
    }

    @Test("The newer save wins, whichever side it is on")
    func newerWins() {
        let older = SaveSync.Version(data: save(1), modified: date(0))
        let newer = SaveSync.Version(data: save(2), modified: date(60))
        #expect(SaveSync.resolve(local: older, remote: newer) == .useRemote)
        #expect(SaveSync.resolve(local: newer, remote: older) == .useLocal)
    }

    /// Identical bytes are not a conflict no matter what the clocks say, and
    /// saying so avoids a pointless write on every launch.
    @Test("Identical saves need no action even when timestamps differ")
    func identicalContent() {
        let here = SaveSync.Version(data: save(7), modified: date(0))
        let there = SaveSync.Version(data: save(7), modified: date(500))
        #expect(SaveSync.resolve(local: here, remote: there) == .noChange)
    }

    /// Two devices, clocks not perfectly aligned. Without a tolerance a save
    /// bounces between them on every launch, each one "newer" by a second.
    @Test("A near-tie keeps the local save rather than flapping")
    func clockSkewDoesNotFlap() {
        let local = SaveSync.Version(data: save(1), modified: date(0))
        let remote = SaveSync.Version(data: save(2), modified: date(2))
        #expect(SaveSync.resolve(local: local, remote: remote) == .useLocal)
    }

    @Test("Beyond the tolerance the newer save is taken")
    func beyondToleranceRemoteWins() {
        let local = SaveSync.Version(data: save(1), modified: date(0))
        let remote = SaveSync.Version(data: save(2), modified: date(30))
        #expect(SaveSync.resolve(local: local, remote: remote) == .useRemote)
    }

    /// A save of the wrong size is not a save. Adopting one would hand the
    /// emulator a PRG-RAM image that does not fit the cartridge.
    @Test("A wrong-sized cloud payload is refused, not adopted")
    func wrongSizedRemoteIsRefused() {
        let local = SaveSync.Version(data: save(1), modified: date(0))
        let truncated = SaveSync.Version(
            data: [UInt8](repeating: 9, count: 128), modified: date(600))
        #expect(SaveSync.resolve(local: local, remote: truncated,
                                 expectedSize: 0x2000) == .useLocal)
        #expect(SaveSync.resolve(local: nil, remote: truncated,
                                 expectedSize: 0x2000) == .noSave)
    }

    /// An all-zero save is what a cartridge looks like before anyone plays it.
    /// Letting a fresh device push that over a real quest is the single most
    /// expensive thing this code could do.
    @Test("An empty cloud save never overwrites real local progress")
    func emptyRemoteNeverBeatsRealProgress() {
        let real = SaveSync.Version(data: save(1), modified: date(0))
        let blank = SaveSync.Version(data: eightK, modified: date(9999))
        #expect(SaveSync.resolve(local: real, remote: blank) == .useLocal)
    }

    @Test("An empty local save is replaced by real cloud progress")
    func realRemoteBeatsEmptyLocal() {
        let blank = SaveSync.Version(data: eightK, modified: date(9999))
        let real = SaveSync.Version(data: save(1), modified: date(0))
        #expect(SaveSync.resolve(local: blank, remote: real) == .useRemote)
    }
}

/// The store behind the resolution, exercised through a fake so these run
/// without an iCloud account, an entitlement, or a network.
@Suite("Save sync store")
struct SaveSyncStoreTests {
    private func eightK(_ marker: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x2000)
        bytes[0] = marker
        return bytes
    }

    @Test("A round trip returns what was stored")
    func roundTrip() {
        let store = FakeKeyValueStore()
        let sync = SaveSync(store: store, key: "zelda")
        sync.write(eightK(3), modified: Date(timeIntervalSince1970: 100))

        let read = sync.read()
        #expect(read?.data == eightK(3))
        #expect(read?.modified == Date(timeIntervalSince1970: 100))
    }

    @Test("An empty store reads as no save rather than as an error")
    func emptyStore() {
        #expect(SaveSync(store: FakeKeyValueStore(), key: "zelda").read() == nil)
    }

    /// Anything in that store came from a previous version of this app or from
    /// nowhere at all; neither is worth crashing over.
    @Test("Corrupt stored data reads as no save")
    func corruptStore() {
        let store = FakeKeyValueStore()
        store.set(Data("not a save".utf8), forKey: "zelda")
        #expect(SaveSync(store: store, key: "zelda").read() == nil)
    }

    @Test("An unavailable store neither reads nor writes")
    func unavailableStore() {
        let store = FakeKeyValueStore()
        store.available = false
        let sync = SaveSync(store: store, key: "zelda")
        sync.write(eightK(1), modified: Date())
        #expect(sync.read() == nil)
        #expect(store.storage.isEmpty)
    }
}
