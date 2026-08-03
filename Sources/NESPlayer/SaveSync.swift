import Foundation

/// A key-value store that can hold small blobs across devices.
///
/// Abstracted so the resolution logic can be tested without an iCloud account,
/// an entitlement, or a network — none of which are available in CI, and all of
/// which would otherwise make the one genuinely risky part of this feature
/// untestable.
public protocol KeyValueStore: AnyObject {
    var isAvailable: Bool { get }
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    /// Pushes pending changes. Best-effort; the system syncs on its own too.
    func synchronize()
}

/// iCloud's key-value store.
///
/// Chosen over CloudKit or an iCloud Documents container because the thing
/// worth syncing is small and the same everywhere. A cartridge battery save is
/// **8 KB** against a 1 MB budget, and `NSUbiquitousKeyValueStore` behaves
/// identically on iOS, macOS and tvOS with no file coordination to get wrong.
///
/// This matters more than convenience on tvOS: an Apple TV gives an app no
/// guaranteed persistent local storage, so a quest that lives only in its
/// Documents directory can be evicted whenever the system wants space. Syncing
/// the battery save is what makes a tvOS build trustworthy rather than merely
/// runnable.
public final class UbiquitousKeyValueStore: KeyValueStore {
    private let store = NSUbiquitousKeyValueStore.default

    public init() {}

    /// False when there is no iCloud account, or the entitlement is missing.
    ///
    /// Both are ordinary states — a signed-out device, or a build signed
    /// without the capability — so they degrade to local-only saves rather
    /// than to an error the player cannot act on.
    public var isAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    public func data(forKey key: String) -> Data? {
        guard isAvailable else { return nil }
        return store.data(forKey: key)
    }

    public func set(_ data: Data, forKey key: String) {
        guard isAvailable else { return }
        store.set(data, forKey: key)
    }

    public func synchronize() {
        guard isAvailable else { return }
        store.synchronize()
    }
}

/// Reads and writes the cartridge battery save through a key-value store, and
/// decides which copy wins when two devices disagree.
public final class SaveSync {
    /// One side's view of the save.
    public struct Version: Equatable {
        public let data: [UInt8]
        public let modified: Date

        public init(data: [UInt8], modified: Date) {
            self.data = data
            self.modified = modified
        }
    }

    public enum Resolution: Equatable {
        /// Neither side has anything worth loading.
        case noSave
        /// Keep what is on this device.
        case useLocal
        /// Adopt what came from the cloud.
        case useRemote
        /// Both sides already agree.
        case noChange
    }

    /// How far apart two timestamps may be before the newer one is believed.
    ///
    /// Device clocks are not identical, and iCloud does not promise ordering.
    /// Without a tolerance, two devices whose clocks differ by a second trade
    /// the save back and forth on every launch, each convinced it is newer.
    public static let clockTolerance: TimeInterval = 5

    /// Whether the backing store can be reached at all.
    public var isAvailable: Bool { store.isAvailable }

    /// What the cloud side of a load looked like.
    ///
    /// Worth naming, and worth logging, because from outside the app these
    /// states are indistinguishable: a device with no iCloud account and a
    /// device syncing perfectly that has nothing stored yet both just carry on
    /// with the local file. Silent degradation is the correct *behaviour* —
    /// nobody should lose a game because they signed out — but it leaves "is
    /// syncing actually working?" with no answer short of buying a second
    /// device.
    public enum CloudStatus: String {
        /// Syncing was never asked for; this build is local-only.
        case off
        /// No iCloud account, or the app is signed without the entitlement.
        case unavailable
        /// Reachable, but holding nothing yet.
        case empty
        /// Reachable, and holding a save.
        case present
    }

    /// Describes the cloud side of a load that has already read `remote`.
    public static func status(of sync: SaveSync?, holding remote: Version?) -> CloudStatus {
        guard let sync else { return .off }
        guard sync.isAvailable else { return .unavailable }
        return remote == nil ? .empty : .present
    }

    private let store: KeyValueStore
    private let key: String

    public init(store: KeyValueStore, key: String) {
        self.store = store
        self.key = key
    }

    /// Decides which copy of the save to use.
    ///
    /// Newer normally wins, with two exceptions that exist because the cost of
    /// being wrong is entirely one-sided — a needless local save costs nothing,
    /// and a needless overwrite costs somebody's quest:
    ///
    /// - **An all-zero save never beats a non-empty one, however new it looks.**
    ///   That is exactly what a cartridge reads as before anyone has played, so
    ///   a freshly installed device would otherwise push "no progress" over a
    ///   finished game the moment it launched.
    /// - **A wrong-sized payload is refused outright.** It cannot be from this
    ///   cartridge, and handing the emulator a PRG-RAM image that does not fit
    ///   is worse than ignoring it.
    public static func resolve(
        local: Version?,
        remote: Version?,
        expectedSize: Int? = nil
    ) -> Resolution {
        func valid(_ version: Version?) -> Version? {
            guard let version else { return nil }
            if let expectedSize, version.data.count != expectedSize { return nil }
            return version
        }

        let local = valid(local)
        let remote = valid(remote)

        switch (local, remote) {
        case (nil, nil):
            return .noSave
        case (.some, nil):
            return .useLocal
        case (nil, .some):
            return .useRemote
        case let (.some(here), .some(there)):
            if here.data == there.data { return .noChange }

            // A blank save is not progress, so it never wins on recency alone.
            let hereEmpty = here.data.allSatisfy { $0 == 0 }
            let thereEmpty = there.data.allSatisfy { $0 == 0 }
            if hereEmpty != thereEmpty { return hereEmpty ? .useRemote : .useLocal }

            let gap = there.modified.timeIntervalSince(here.modified)
            return gap > clockTolerance ? .useRemote : .useLocal
        }
    }

    /// Picks the newer of two snapshots, by time alone.
    ///
    /// Deliberately *not* `resolve`. That one compares content and refuses an
    /// all-zero payload, both of which are battery-save concerns: a blank
    /// cartridge is a real and dangerous state, whereas a snapshot is either
    /// present or absent. Reusing it here was an actual bug — the local side
    /// had no bytes to hand, `[].allSatisfy` is vacuously true, so the
    /// empty-payload guard fired and the remote snapshot won every time
    /// regardless of when either was written.
    public static func resolveByTime(local: Date?, remote: Date?) -> Resolution {
        switch (local, remote) {
        case (nil, nil): .noSave
        case (.some, nil): .useLocal
        case (nil, .some): .useRemote
        case let (.some(here), .some(there)):
            there.timeIntervalSince(here) > clockTolerance ? .useRemote : .useLocal
        }
    }

    // MARK: Transport

    /// What the store currently holds, or nil when there is nothing usable.
    public func read() -> Version? {
        guard let raw = store.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: raw)
        else { return nil }
        return Version(
            data: [UInt8](payload.data),
            modified: Date(timeIntervalSince1970: payload.modified))
    }

    public func write(_ data: [UInt8], modified: Date) {
        let payload = Payload(data: Data(data), modified: modified.timeIntervalSince1970)
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        store.set(encoded, forKey: key)
        store.synchronize()
    }

    /// Timestamp travels with the bytes rather than relying on the store's own
    /// metadata, which key-value stores do not expose.
    private struct Payload: Codable {
        let data: Data
        let modified: TimeInterval
    }
}

/// An in-memory store, for tests.
final class FakeKeyValueStore: KeyValueStore {
    var storage: [String: Data] = [:]
    var available = true
    private(set) var synchronizeCount = 0

    var isAvailable: Bool { available }

    func data(forKey key: String) -> Data? {
        guard available else { return nil }
        return storage[key]
    }

    func set(_ data: Data, forKey key: String) {
        guard available else { return }
        storage[key] = data
    }

    func synchronize() { synchronizeCount += 1 }
}

/// Compresses machine snapshots for syncing.
///
/// A snapshot is JSON, and most of it is byte arrays written out as decimal
/// text — `prgRAM` and CHR-RAM alone are two thirds of it. That compresses
/// about five to one: a measured 61,279-byte snapshot becomes 13,140.
///
/// The difference decides whether syncing snapshots is reasonable at all.
/// iCloud's key-value store allows 1 MB in total, so 61 KB per snapshot is a
/// careless share of a shared budget and 13 KB is not.
enum SnapshotCodec {
    static func compress(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        guard let squeezed = try? (Data(bytes) as NSData).compressed(using: .zlib)
        else { return nil }
        return [UInt8](squeezed as Data)
    }

    /// Returns nil for anything that is not actually a compressed snapshot,
    /// rather than throwing. A payload written by a different version of this
    /// app, or truncated in transit, is an ordinary state — the app falls back
    /// to a normal boot.
    static func decompress(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        guard let expanded = try? (Data(bytes) as NSData).decompressed(using: .zlib)
        else { return nil }
        return [UInt8](expanded as Data)
    }
}
