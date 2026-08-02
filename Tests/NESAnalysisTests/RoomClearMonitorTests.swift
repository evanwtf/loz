@testable import NESAnalysis
import Testing

/// "The room is empty" is a decision made from a sequence of observations, not
/// from any single one, and every rule here exists because a simpler version
/// got a real room wrong.
@Suite("Room clear monitor")
struct RoomClearMonitorTests {
    private func monitor(confirm: Int = 6, grace: Int = 6) -> RoomClearMonitor {
        RoomClearMonitor(confirmTicks: confirm, spawnGraceTicks: grace)
    }

    /// Measured on room $72: entering, the slot table reads all zero for about
    /// 24 frames before the Keese appear. A monitor that trusted the first
    /// observation would call every room clear on arrival.
    @Test("An empty table during the spawn window is not a clear")
    func spawnWindowIsNotAClear() {
        var m = monitor(confirm: 2, grace: 6)
        for _ in 0..<6 { #expect(m.observe(liveEnemies: 0) == false) }
    }

    @Test("Enemies appearing after the spawn window reset the count")
    func enemiesAfterSpawnWindow() {
        var m = monitor(confirm: 2, grace: 6)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 3) == false)
        #expect(m.sawEnemies)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == true)
    }

    /// A genuinely empty room still has to terminate, or a route that walks
    /// through a cleared room hangs until --max-frames.
    @Test("A room that never spawns anything clears once the grace expires")
    func genuinelyEmptyRoomStillClears() {
        var m = monitor(confirm: 2, grace: 3)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == true)
    }

    /// One empty read is not a clear even after a fight: a dying enemy stops
    /// being counted a few frames before the next one is committed to a slot.
    @Test("A single empty observation after a fight is not a clear")
    func singleEmptyReadIsNotAClear() {
        var m = monitor(confirm: 6, grace: 0)
        #expect(m.observe(liveEnemies: 3) == false)
        for _ in 0..<5 { #expect(m.observe(liveEnemies: 0) == false) }
        #expect(m.observe(liveEnemies: 0) == true)
    }

    @Test("An enemy reappearing mid-confirmation restarts the confirmation")
    func reappearanceRestartsConfirmation() {
        var m = monitor(confirm: 3, grace: 0)
        #expect(m.observe(liveEnemies: 2) == false)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 1) == false)
        #expect(m.emptyTicks == 0)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == false)
        #expect(m.observe(liveEnemies: 0) == true)
    }

    /// Once it has said cleared it keeps saying cleared, so a caller that polls
    /// one extra time does not get a different answer.
    @Test("The cleared verdict is stable")
    func verdictIsStable() {
        var m = monitor(confirm: 1, grace: 0)
        #expect(m.observe(liveEnemies: 1) == false)
        #expect(m.observe(liveEnemies: 0) == true)
        #expect(m.observe(liveEnemies: 0) == true)
    }
}
