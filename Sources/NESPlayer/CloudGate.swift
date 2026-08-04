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

/// What the launch found, for the iCloud loading screen to report.
///
/// Exists so "did my quest come down from iCloud?" has an answer on screen
/// rather than only in the log — a device is not always next to a Mac, and on
/// an Apple TV it never is.
public struct SaveReport: Equatable, Sendable {
    public let gate: CloudGate.Outcome
    public let cloud: SaveSync.CloudStatus
    public let battery: SaveSync.Resolution
    public let snapshotFromCloud: Bool
    /// When the save sitting in iCloud was written, if there is one.
    public let cloudSaveModified: Date?
    /// When the resume snapshot taken from iCloud was written, if one was.
    public let cloudSnapshotModified: Date?

    public init(
        gate: CloudGate.Outcome,
        cloud: SaveSync.CloudStatus,
        battery: SaveSync.Resolution,
        snapshotFromCloud: Bool,
        cloudSaveModified: Date? = nil,
        cloudSnapshotModified: Date? = nil
    ) {
        self.gate = gate
        self.cloud = cloud
        self.battery = battery
        self.snapshotFromCloud = snapshotFromCloud
        self.cloudSaveModified = cloudSaveModified
        self.cloudSnapshotModified = cloudSnapshotModified
    }

    /// When whatever came from iCloud was written.
    ///
    /// A resumed snapshot wins over the battery save because it is the newer
    /// and more specific thing — "where you actually were" rather than "where
    /// the game last recorded you".
    public var cloudDate: Date? {
        if snapshotFromCloud, let cloudSnapshotModified { return cloudSnapshotModified }
        return cloudSaveModified
    }

    /// Which state this is, in the order the player needs to hear it.
    ///
    /// Ordered by what matters to them rather than by how the checks happen to
    /// run: something arriving from another device outranks the steady state,
    /// and a broken configuration outranks both — an empty file screen is
    /// alarming, and saying iCloud could not be reached turns it from a lost
    /// quest into a settings problem.
    private enum State {
        case off, unreachable, loadedFromCloud, resumedFromCloud
        case connectedNoSaves, connectedNewQuest, upToDate
    }

    private var state: State {
        if cloud == .off { return .off }
        if cloud == .unavailable { return .unreachable }
        if battery == .useRemote { return .loadedFromCloud }
        if snapshotFromCloud { return .resumedFromCloud }
        if cloud == .empty { return .connectedNoSaves }
        if battery == .noSave { return .connectedNewQuest }
        return .upToDate
    }

    /// What happened, in one short line.
    ///
    /// Written for somebody who does not know what a key-value store is and
    /// should not have to. No jargon, no state names, and never a bare
    /// "unavailable" — the player's question is "where is my game", so the
    /// answer names the game, not the mechanism.
    public var headline: String {
        switch state {
        case .off: "Saved games stay on this device"
        case .unreachable: "Can't reach iCloud"
        case .loadedFromCloud: "Saved game loaded from iCloud"
        case .resumedFromCloud: "Picking up where you left off"
        case .connectedNoSaves, .connectedNewQuest: "Connected to iCloud"
        case .upToDate: "Saved games are up to date"
        }
    }

    /// What it means for them — the consequence, and what to do about it.
    public var detail: String {
        switch state {
        case .off:
            "This copy of the game doesn't use iCloud, so your progress is kept here only."
        case .unreachable:
            "Your game will still save on this device, but it won't appear on your "
                + "other devices. Check that you're signed in to iCloud in Settings."
        case .loadedFromCloud:
            "Your progress from another device is ready to play."
        case .resumedFromCloud:
            "Continuing from the moment you stopped playing on another device."
        case .connectedNoSaves:
            "There are no saved games yet. Once you save, your progress will "
                + "appear on your other devices too."
        case .connectedNewQuest:
            "No saved game on this device yet. Start a quest and it will be "
                + "shared with your other devices."
        case .upToDate:
            "Your progress matches your other devices."
        }
    }

    /// Whether this reports a problem rather than a normal state, so the screen
    /// can colour it. Only the unreachable case qualifies: having no saves yet
    /// is not a fault, and colouring it like one would alarm a new player.
    public var isWarning: Bool { state == .unreachable }

    /// When the iCloud copy was written, as "3 hours ago — Aug 3, 2026 at
    /// 3:42 PM PDT", or nil when nothing came from iCloud.
    ///
    /// Both halves earn their place. The relative half is what a player
    /// actually wants ("is this the game I was playing at lunch?"), and the
    /// absolute half is what settles an argument between two devices — which
    /// is the entire reason somebody would be reading this screen closely.
    ///
    /// Shown in the device's own time zone, and **always labelled with it** —
    /// an unlabelled clock reading is worse than none, because it looks
    /// authoritative while meaning nothing to a device in another country.
    ///
    /// "Local if possible, UTC otherwise" needs no special case: `TimeZone`
    /// always resolves one, falling back to GMT itself on a device that knows
    /// no better, and every zone can name itself — even an odd offset returns
    /// `GMT+0:07`. A device with no zone information therefore prints GMT and
    /// says so, which is the desired behaviour arrived at for free. The `??`
    /// below is a total default on an Optional API, not a second code path.
    public func savedAt(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String? {
        guard let date = cloudDate else { return nil }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let zone = timeZone.abbreviation(for: date) ?? "UTC"
        return "\(Self.relative(from: date, to: now)) — \(formatter.string(from: date)) \(zone)"
    }

    /// Plain relative time, spelled out rather than left to
    /// `RelativeDateTimeFormatter`.
    ///
    /// The formatter's wording shifts with style and locale, which makes the
    /// one thing worth asserting — that this reads like something a person
    /// said — untestable. This is a handful of branches and is exact.
    static func relative(from date: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        // A save written "in the future" means the two devices disagree about
        // the clock, not that the player has a time machine.
        guard seconds >= 0 else { return "just now" }

        let minutes = Int(seconds) / 60
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1 minute ago" }
        if minutes < 60 { return "\(minutes) minutes ago" }

        let hours = minutes / 60
        if hours == 1 { return "1 hour ago" }
        if hours < 24 { return "\(hours) hours ago" }

        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }

        let weeks = days / 7
        if weeks == 1 { return "last week" }
        if days < 365 { return "\(weeks) weeks ago" }

        let years = days / 365
        return years == 1 ? "a year ago" : "\(years) years ago"
    }

    /// The symbol shown above the headline.
    public var symbol: String {
        switch state {
        case .off: "iphone"
        case .unreachable: "exclamationmark.icloud"
        case .loadedFromCloud, .resumedFromCloud: "icloud.and.arrow.down"
        case .connectedNoSaves, .connectedNewQuest: "icloud"
        case .upToDate: "checkmark.icloud"
        }
    }
}
