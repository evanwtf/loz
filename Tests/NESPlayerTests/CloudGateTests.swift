import Foundation
@testable import NESPlayer
import Testing

/// Waiting for iCloud to hand over another device's save before reading it.
///
/// The bug this exists for is ordered rather than random: the store reads from
/// a local cache, values from other devices arrive after, so the first launch
/// on a new device reads an empty store and shows an empty file screen. It
/// works on the second launch, which is what makes it look intermittent.
///
/// The risk in fixing it is the opposite failure — delaying every launch to
/// catch a case that only happens once. So most of these assert that the gate
/// does *not* wait.
@Suite("Cloud gate")
struct CloudGateTests {
    private let key = "battery-save"

    @MainActor
    private func gate(_ store: FakeKeyValueStore) -> CloudGate {
        CloudGate(store: store, pollInterval: .milliseconds(10))
    }

    /// Nothing will ever arrive, so waiting would be pure delay.
    @Test("An unavailable store does not wait")
    @MainActor
    func unavailableReturnsAtOnce() async {
        let store = FakeKeyValueStore()
        store.available = false
        let outcome = await gate(store)
            .wait(forKey: key, timeout: .seconds(30))
        #expect(outcome == .unavailable)
        #expect(outcome.waited == false)
    }

    /// The common case, and the one that must stay fast: every launch after
    /// the first.
    @Test("A store that already holds the key does not wait")
    @MainActor
    func cachedReturnsAtOnce() async {
        let store = FakeKeyValueStore()
        store.set(Data([1, 2, 3]), forKey: key)
        let outcome = await gate(store)
            .wait(forKey: key, timeout: .seconds(30))
        #expect(outcome == .cached)
        #expect(outcome.waited == false)
    }

    /// A pull has to be requested or the wait is just a sleep.
    @Test("Waiting asks iCloud to reconcile first")
    @MainActor
    func synchronizesBeforeWaiting() async {
        let store = FakeKeyValueStore()
        _ = await gate(store)
            .wait(forKey: key, timeout: .milliseconds(20))
        #expect(store.synchronizeCount >= 1)
    }

    @Test("Nothing arriving times out rather than hanging")
    @MainActor
    func timesOut() async {
        let outcome = await gate(FakeKeyValueStore())
            .wait(forKey: key, timeout: .milliseconds(50))
        #expect(outcome == .timedOut)
    }

    /// The case the gate exists for.
    ///
    /// Arrival is expressed as "the store starts answering on the third read"
    /// rather than as a sleep followed by a write, so nothing here depends on
    /// timing. The previous version did, and it cost more than it tested: it
    /// raced an observer's attach, and when it lost, the gate ran its full
    /// timeout — which showed up as a suite that occasionally took four times
    /// as long and failed *a different test*, because the stall starved an
    /// unrelated utility-priority write. One flake, two symptoms, neither
    /// pointing here.
    @Test("A save arriving while waiting is reported, and ends the wait early")
    @MainActor
    func deliveryWins() async {
        // Read 1 is the "already cached?" check and must miss, or this would
        // be testing `.cached` by accident.
        let store = ArrivingStore(payload: Data([1, 2, 3]), afterReads: 2)

        let outcome = await CloudGate(store: store, pollInterval: .milliseconds(10))
            .wait(forKey: key, timeout: .seconds(20))

        // `.delivered` is itself the proof that it woke on the arrival: a wait
        // that ran its course reports `.timedOut`, and one that never waited
        // reports `.cached`.
        //
        // Deliberately no elapsed-time bound. `CloudGate` is main-actor
        // isolated and sibling suites block that actor with synchronous tick()
        // loops, so wall-clock here measures the machine rather than the code —
        // a 20 ms wait was observed taking 10.6 s under a full parallel run.
        #expect(outcome == .delivered)
    }
}

/// A store that has nothing until it has been asked a few times, standing in
/// for iCloud handing the save over partway through a wait.
private final class ArrivingStore: KeyValueStore {
    private let payload: Data
    private let afterReads: Int
    private var reads = 0

    var isAvailable = true

    init(payload: Data, afterReads: Int) {
        self.payload = payload
        self.afterReads = afterReads
    }

    func data(forKey _: String) -> Data? {
        reads += 1
        return reads > afterReads ? payload : nil
    }

    func set(_: Data, forKey _: String) {}

    @discardableResult
    func synchronize() -> Bool { isAvailable }
}

/// What the iCloud loading screen tells the player.
///
/// The audience is somebody who does not know what a key-value store is and
/// should not have to. Two things are being tested: that the right *state* is
/// chosen, and that each one says what it means for the player's saved game
/// rather than for the storage layer.
///
/// The ordering is the substance: an empty file screen is alarming, so a
/// configuration problem has to outrank the steady state or the player
/// concludes their quest is gone.
@Suite("iCloud loading screen copy")
struct SaveReportTests {
    private func report(
        gate: CloudGate.Outcome = .cached,
        cloud: SaveSync.CloudStatus,
        battery: SaveSync.Resolution = .useLocal,
        snapshot: Bool = false
    ) -> SaveReport {
        SaveReport(gate: gate, cloud: cloud, battery: battery, snapshotFromCloud: snapshot)
    }

    /// Every distinct situation the screen can report.
    private var everyState: [SaveReport] {
        [report(cloud: .off),
         report(cloud: .unavailable, battery: .noSave),
         report(cloud: .present, battery: .useRemote),
         report(cloud: .present, battery: .noChange, snapshot: true),
         report(cloud: .empty, battery: .noSave),
         report(cloud: .present, battery: .noSave),
         report(cloud: .present, battery: .useLocal)]
    }

    @Test("A build without syncing says where the game is kept")
    func off() {
        let r = report(cloud: .off)
        #expect(r.headline == "Saved games stay on this device")
        #expect(r.detail.contains("kept here only"))
        #expect(r.isWarning == false)
    }

    /// The one that must not be mistaken for a lost quest — and the only one
    /// the player can actually do something about, so it says what.
    @Test("An unreachable store is a warning, and tells the player what to check")
    func unavailable() {
        let r = report(cloud: .unavailable, battery: .noSave)
        #expect(r.headline == "Can't reach iCloud")
        #expect(r.detail.contains("still save on this device"))
        #expect(r.detail.contains("signed in to iCloud"))
        #expect(r.isWarning)
    }

    @Test("Adopting the cloud quest outranks everything but a broken store")
    func adopted() {
        #expect(report(cloud: .present, battery: .useRemote).headline
            == "Saved game loaded from iCloud")
    }

    @Test("A cloud snapshot is reported when the battery save did not change")
    func resumed() {
        #expect(report(cloud: .present, battery: .noChange, snapshot: true).headline
            == "Picking up where you left off")
    }

    /// Distinct from unreachable on purpose: one is a settings problem and the
    /// other is a device that has simply never saved. Both are calm.
    @Test("A reachable but empty store is not reported as a failure")
    func empty() {
        let r = report(cloud: .empty, battery: .noSave)
        #expect(r.headline == "Connected to iCloud")
        #expect(r.detail.contains("no saved games yet"))
        #expect(r.isWarning == false)
    }

    @Test("A first quest on a working store reads as new, not as empty cloud")
    func newQuest() {
        let r = report(cloud: .present, battery: .noSave)
        #expect(r.headline == "Connected to iCloud")
        #expect(r.detail.contains("Start a quest"))
    }

    @Test("The steady state is the quiet one")
    func upToDate() {
        let r = report(cloud: .present, battery: .useLocal)
        #expect(r.headline == "Saved games are up to date")
        #expect(r.isWarning == false)
    }

    @Test("Only an unreachable store is coloured as a warning")
    func onlyUnreachableWarns() {
        let warning = everyState.filter(\.isWarning)
        #expect(warning.count == 1)
        #expect(warning.first?.headline == "Can't reach iCloud")
    }

    /// A blank line on a screen whose whole job is to explain something would
    /// be worse than not showing the screen.
    @Test("Every state has a headline, a detail, and a symbol")
    func nothingIsBlank() {
        for r in everyState {
            #expect(!r.headline.isEmpty)
            #expect(!r.detail.isEmpty)
            #expect(!r.symbol.isEmpty)
            // The detail explains; a headline-length restatement does not.
            #expect(r.detail.count > r.headline.count)
        }
    }

    /// The screen exists for people who would not recognise these words. If one
    /// reappears the copy has drifted back toward describing the machine.
    @Test("No implementation vocabulary reaches the player")
    func noJargon() {
        let jargon = ["key-value", "entitlement", "store", "payload", "sync ",
                      "cache", "snapshot", "battery", "unavailable", "nil"]
        for r in everyState {
            let copy = (r.headline + " " + r.detail).lowercased()
            for word in jargon {
                #expect(!copy.contains(word), "\"\(word)\" in: \(copy)")
            }
        }
    }
}

/// When the iCloud copy was written.
///
/// Two audiences in one line: the relative half answers "is this the game I
/// was playing at lunch?", and the absolute half settles an argument between
/// two devices — which is why somebody would be reading this screen closely in
/// the first place.
@Suite("iCloud save timestamp")
struct SaveTimestampTests {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private let english = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(
        saved: Date? = nil,
        snapshot: Date? = nil,
        fromSnapshot: Bool = false,
        cloud: SaveSync.CloudStatus = .present
    ) -> SaveReport {
        SaveReport(gate: .cached, cloud: cloud, battery: .useRemote,
                   snapshotFromCloud: fromSnapshot,
                   cloudSaveModified: saved, cloudSnapshotModified: snapshot)
    }

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    @Test("Nothing from iCloud means no timestamp at all")
    func noDate() {
        #expect(report(cloud: .empty).savedAt(now: now) == nil)
    }

    /// The point of the line: a player recognising their own session.
    @Test("Relative time reads the way a person would say it")
    func relativeWording() {
        let cases: [(TimeInterval, String)] = [
            (10, "just now"),
            (60, "1 minute ago"),
            (25 * 60, "25 minutes ago"),
            (3600, "1 hour ago"),
            (5 * 3600, "5 hours ago"),
            (26 * 3600, "yesterday"),
            (3 * 86400, "3 days ago"),
            (8 * 86400, "last week"),
            (20 * 86400, "2 weeks ago"),
            (400 * 86400, "a year ago"),
        ]
        for (seconds, expected) in cases {
            #expect(SaveReport.relative(from: ago(seconds), to: now) == expected,
                    "\(seconds)s should read \"\(expected)\"")
        }
    }

    /// Two devices whose clocks disagree is ordinary; a save from the future is
    /// not something to render as "in -3 hours".
    @Test("A save written in the future reads as just now, not as negative time")
    func futureSave() {
        #expect(SaveReport.relative(from: now.addingTimeInterval(9000), to: now)
            == "just now")
    }

    @Test("The absolute half names the zone it is written in")
    func absoluteIsLabelled() {
        let line = report(saved: ago(3 * 3600))
            .savedAt(now: now, timeZone: pacific, locale: english)
        #expect(line?.hasPrefix("3 hours ago — ") == true)
        // Whatever the date format, the zone must be named or the clock time
        // means nothing on a device in another country.
        #expect(line?.contains("PDT") == true || line?.contains("PST") == true)
    }

    /// The invariant behind "local time zone if possible, UTC otherwise".
    ///
    /// It needs no fallback code, and an earlier version of this test pretended
    /// otherwise: it asserted a UTC branch that could never run, and passed
    /// vacuously through its own `||`. Every zone names itself — an odd offset
    /// returns `GMT+0:07` — and a device that knows no zone gets GMT from
    /// Foundation and prints GMT. So the real thing worth guarding is that a
    /// clock reading is *never* shown unlabelled.
    @Test("Every zone labels itself, including odd offsets and GMT")
    func clockTimeIsNeverUnlabelled() throws {
        let zones = try [TimeZone(secondsFromGMT: 7 * 60)!,   // GMT+0:07
                         #require(TimeZone(secondsFromGMT: 0)),        // GMT
                         #require(TimeZone(identifier: "Asia/Kathmandu")),
                         pacific]
        for zone in zones {
            let line = report(saved: ago(3600))
                .savedAt(now: now, timeZone: zone, locale: english)
            let label = zone.abbreviation(for: ago(3600))
            #expect(label != nil, "\(zone.identifier) named itself as nil")
            #expect(line?.hasSuffix(" " + (label ?? "UTC")) == true,
                    "unlabelled clock time for \(zone.identifier): \(line ?? "nil")")
        }
    }

    /// The snapshot is the newer and more specific thing — where the player
    /// actually was, not where the game last recorded them.
    @Test("A resumed snapshot's time wins over the battery save's")
    func snapshotWins() {
        let r = report(saved: ago(10 * 3600), snapshot: ago(3600), fromSnapshot: true)
        #expect(r.cloudDate == ago(3600))
        #expect(r.savedAt(now: now, timeZone: pacific, locale: english)?
            .hasPrefix("1 hour ago") == true)
    }

    @Test("Without a snapshot the battery save's time is used")
    func batterySaveUsed() {
        let r = report(saved: ago(10 * 3600), snapshot: ago(3600), fromSnapshot: false)
        #expect(r.cloudDate == ago(10 * 3600))
    }
}
