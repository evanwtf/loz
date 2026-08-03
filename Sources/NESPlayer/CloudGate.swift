import Foundation

/// Gives iCloud a moment to hand over another device's saves before the game
/// reads them.
///
/// `NSUbiquitousKeyValueStore` reads are synchronous against a *local* cache,
/// and values from other devices arrive asynchronously afterwards. So a launch
/// that reads the store immediately gets whatever happened to be cached at that
/// instant — and on a fresh install that is nothing at all. The quest lands a
/// few seconds later, unread, and the player sees an empty file screen on a
/// device that is syncing perfectly. Next launch it works, which makes the bug
/// look intermittent rather than ordered.
///
/// Waiting is only worth it when there is nothing to lose. Three of the four
/// outcomes return immediately:
///
/// - **`unavailable`** — no account or no entitlement. Nothing will ever
///   arrive, so waiting is pure delay.
/// - **`cached`** — the store already holds this key. Whatever is here is at
///   least as good as a normal launch would have used, and a newer value can
///   land next time; adding seconds to every launch to catch that is a bad
///   trade.
/// - **`delivered`** — iCloud handed something over while we waited. This is
///   the case the gate exists for.
/// - **`timedOut`** — nothing arrived. Carry on with local saves.
///
/// So the wait happens on exactly one launch: the first one on a device that
/// has an account, an entitlement, and no local copy yet.
@MainActor
public final class CloudGate {
    public enum Outcome: Equatable, Sendable {
        /// No iCloud account, or the app is signed without the entitlement.
        case unavailable
        /// The store already holds a value; no reason to wait for one.
        case cached
        /// iCloud delivered values from another device while we waited.
        case delivered
        /// The wait elapsed with nothing arriving.
        case timedOut

        /// Whether the player was made to wait for this.
        public var waited: Bool { self == .delivered || self == .timedOut }
    }

    private let store: KeyValueStore
    private let pollInterval: Duration

    /// The interval is injected so tests need not wait in real time.
    public init(store: KeyValueStore, pollInterval: Duration = .milliseconds(150)) {
        self.store = store
        self.pollInterval = pollInterval
    }

    /// Waits for `key` to arrive from iCloud, up to `timeout`.
    ///
    /// Polls rather than observing `didChangeExternallyNotification`, which
    /// looks like the obvious mechanism and is the wrong one here. There is a
    /// window between the `synchronize()` below and any observer being
    /// attached, and a delivery landing in it is missed completely — after
    /// which the gate waits out its whole timeout with the save already sitting
    /// in the store. Asking the store directly cannot miss anything, whenever
    /// it arrives.
    ///
    /// The notification only ever saved one poll interval, and the first
    /// version of this cost far more than it saved: the observer race made a
    /// test hang for its full timeout, which starved an unrelated
    /// utility-priority write and failed a different suite. One flake, two
    /// symptoms, and neither pointed here.
    public func wait(forKey key: String, timeout: Duration) async -> Outcome {
        guard store.isAvailable else { return .unavailable }

        // Ask for a pull before deciding to wait: synchronize() is what
        // prompts the daemon to reconcile, and without it the wait is just a
        // sleep.
        store.synchronize()
        if store.data(forKey: key) != nil { return .cached }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            if store.data(forKey: key) != nil { return .delivered }
        }
        return .timedOut
    }
}

/// What the launch found, for the interstitial to report.
///
/// Exists so "did my quest come down from iCloud?" has an answer on screen
/// rather than only in the log — a device is not always next to a Mac, and on
/// an Apple TV it never is.
public struct SaveReport: Equatable, Sendable {
    public let gate: CloudGate.Outcome
    public let cloud: SaveSync.CloudStatus
    public let battery: SaveSync.Resolution
    public let snapshotFromCloud: Bool

    public init(
        gate: CloudGate.Outcome,
        cloud: SaveSync.CloudStatus,
        battery: SaveSync.Resolution,
        snapshotFromCloud: Bool
    ) {
        self.gate = gate
        self.cloud = cloud
        self.battery = battery
        self.snapshotFromCloud = snapshotFromCloud
    }

    /// One line a player can act on.
    ///
    /// Ordered by what the player most needs to know rather than by how the
    /// checks happen to run: something arriving from another device outranks
    /// the steady state, and a broken configuration outranks both — an empty
    /// file screen is alarming, and "iCloud unavailable" turns it from a lost
    /// quest into a settings problem.
    public var summary: String {
        if cloud == .off { return "Local saves only" }
        if cloud == .unavailable { return "iCloud unavailable — using local saves" }
        if battery == .useRemote { return "Quest loaded from iCloud" }
        if snapshotFromCloud { return "Resumed from another device" }
        if cloud == .empty { return "iCloud connected — nothing saved yet" }
        if battery == .noSave { return "iCloud connected — new quest" }
        return "iCloud up to date"
    }

    /// Whether the summary reports a problem rather than a normal state.
    public var isWarning: Bool { cloud == .unavailable }
}
