import Foundation

/// Where this platform actually lets the app keep files.
///
/// Exists because `.applicationSupportDirectory` is not writable on tvOS —
/// it cannot even be created — and every call site swallowed the failure with
/// `try?`. The result was a nil URL, and a nil URL made every save path exit
/// at its first guard: no battery save, no auto-resume snapshot, and no save
/// state slots, silently, for the entire life of the tvOS app.
///
/// It presented as an iCloud problem, which is what made it expensive. The
/// Apple TV read the cloud copy correctly at every launch and never wrote one,
/// because writing began with a local file that could not exist. A quest saved
/// on the TV vanished; a quest from another device reappeared in its place.
///
/// tvOS gives an app **no guaranteed persistent storage** — Caches is what
/// there is, and the system may evict it. That is not a workaround here, it is
/// the platform's model, and it is the reason the battery save syncs through
/// iCloud in the first place. Caches plus iCloud is the durable pair; Caches
/// alone is a cache.
enum SaveLocation {
    /// The writable root for this platform, created if needed.
    private static var base: URL? {
        // Ordered by preference. tvOS is given Caches only because
        // Application Support is not merely unwritable there, it is
        // unavailable — asking for it wastes a syscall and returns nil.
        #if os(tvOS)
            let candidates: [FileManager.SearchPathDirectory] = [.cachesDirectory]
        #else
            let candidates: [FileManager.SearchPathDirectory] =
                [.applicationSupportDirectory, .cachesDirectory]
        #endif

        for candidate in candidates {
            if let url = try? FileManager.default.url(
                for: candidate, in: .userDomainMask, appropriateFor: nil, create: true)
            {
                return url
            }
        }
        return nil
    }

    /// A directory under the app's writable root, created if needed.
    ///
    /// Returns nil only when the platform gave us nowhere at all to write,
    /// which callers must treat as "keep going without a file" rather than as
    /// a reason to stop — on tvOS the cloud copy is the real store.
    static func directory(_ components: String...) -> URL? {
        guard let base else { return nil }
        var directory = base
        for component in components {
            directory = directory.appendingPathComponent(component, isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A file under the app's writable root.
    static func file(_ name: String, in components: String...) -> URL? {
        var directory = base
        for component in components {
            directory = directory?.appendingPathComponent(component, isDirectory: true)
        }
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
