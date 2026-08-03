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
    private let name = Notification.Name("test.kvstore.changed")

    @MainActor
    private func gate(_ store: FakeKeyValueStore, _ center: NotificationCenter) -> CloudGate {
        CloudGate(store: store, center: center, notification: name)
    }

    /// Nothing will ever arrive, so waiting would be pure delay.
    @Test("An unavailable store does not wait")
    @MainActor
    func unavailableReturnsAtOnce() async {
        let store = FakeKeyValueStore()
        store.available = false
        let outcome = await gate(store, NotificationCenter())
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
        let outcome = await gate(store, NotificationCenter())
            .wait(forKey: key, timeout: .seconds(30))
        #expect(outcome == .cached)
        #expect(outcome.waited == false)
    }

    /// A pull has to be requested or the wait is just a sleep.
    @Test("Waiting asks iCloud to reconcile first")
    @MainActor
    func synchronizesBeforeWaiting() async {
        let store = FakeKeyValueStore()
        _ = await gate(store, NotificationCenter())
            .wait(forKey: key, timeout: .milliseconds(20))
        #expect(store.synchronizeCount >= 1)
    }

    @Test("Nothing arriving times out rather than hanging")
    @MainActor
    func timesOut() async {
        let outcome = await gate(FakeKeyValueStore(), NotificationCenter())
            .wait(forKey: key, timeout: .milliseconds(50))
        #expect(outcome == .timedOut)
    }

    /// The case the gate exists for.
    @Test("A delivery while waiting is reported, and ends the wait early")
    @MainActor
    func deliveryWins() async {
        let center = NotificationCenter()
        let store = FakeKeyValueStore()

        let waiting = Task { @MainActor in
            await gate(store, center).wait(forKey: key, timeout: .seconds(30))
        }
        // Let the observer attach before posting, otherwise the notification
        // is delivered to nobody and this passes only by timing out.
        try? await Task.sleep(for: .milliseconds(100))
        center.post(name: name, object: nil)

        let started = ContinuousClock.now
        let outcome = await waiting.value
        #expect(outcome == .delivered)
        // Proves it woke on the notification rather than the 30s timeout.
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

/// What the interstitial tells the player.
///
/// The ordering is the whole content here: an empty file screen is alarming,
/// so a configuration problem has to outrank the steady state or the player
/// concludes their quest is gone.
@Suite("Save report summary")
struct SaveReportTests {
    private func report(
        gate: CloudGate.Outcome = .cached,
        cloud: SaveSync.CloudStatus,
        battery: SaveSync.Resolution = .useLocal,
        snapshot: Bool = false
    ) -> SaveReport {
        SaveReport(gate: gate, cloud: cloud, battery: battery, snapshotFromCloud: snapshot)
    }

    @Test("A build without syncing says so plainly")
    func off() {
        #expect(report(cloud: .off).summary == "Local saves only")
        #expect(report(cloud: .off).isWarning == false)
    }

    /// The one that must not be mistaken for a lost quest.
    @Test("An unavailable store is reported as a warning, not as no save")
    func unavailable() {
        let r = report(cloud: .unavailable, battery: .noSave)
        #expect(r.summary == "iCloud unavailable — using local saves")
        #expect(r.isWarning)
    }

    @Test("Adopting the cloud quest outranks everything but a broken store")
    func adopted() {
        #expect(report(cloud: .present, battery: .useRemote).summary
            == "Quest loaded from iCloud")
    }

    @Test("A cloud snapshot is reported when the battery save did not change")
    func resumed() {
        #expect(report(cloud: .present, battery: .noChange, snapshot: true).summary
            == "Resumed from another device")
    }

    /// Distinct from "unavailable" on purpose: one is a settings problem and
    /// the other is a device that has simply never saved.
    @Test("A reachable but empty store is not reported as a failure")
    func empty() {
        let r = report(cloud: .empty, battery: .noSave)
        #expect(r.summary == "iCloud connected — nothing saved yet")
        #expect(r.isWarning == false)
    }

    @Test("A first quest on a working store reads as new, not as empty cloud")
    func newQuest() {
        #expect(report(cloud: .present, battery: .noSave).summary
            == "iCloud connected — new quest")
    }

    @Test("The steady state is the quiet one")
    func upToDate() {
        #expect(report(cloud: .present, battery: .useLocal).summary == "iCloud up to date")
    }
}
