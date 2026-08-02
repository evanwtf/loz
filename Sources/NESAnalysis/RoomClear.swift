/// Decides when a room has actually been cleared, from a sequence of enemy
/// counts rather than any single reading.
///
/// Two separate mistakes are possible here and they pull in opposite
/// directions, which is why this is a small state machine and not a comparison
/// against zero:
///
/// - **Too eager.** A room's enemies are not in their slots the instant the
///   room loads. Measured on Level 1 room `$72`, the table reads all zero for
///   about 24 frames after entry before three Keese appear. A loop that
///   believed the first observation would declare every room clear on arrival
///   and walk straight into the fight it thought it had skipped.
/// - **Too eager again, later.** A dying enemy leaves its slot a few frames
///   before the next observation, so a single empty read mid-fight is not the
///   end of the fight.
///
/// The counter-pressure is that a genuinely empty room still has to terminate,
/// or a route that passes through a cleared room hangs until `--max-frames`.
/// So the spawn grace is a *window*, not a precondition: once it expires,
/// nothing having appeared is itself an answer.
public struct RoomClearMonitor {
    /// Consecutive empty observations before the room counts as cleared.
    public let confirmTicks: Int

    /// How long to keep waiting for enemies to appear before an empty table is
    /// allowed to mean "there were never any".
    public let spawnGraceTicks: Int

    /// Whether any enemy has been seen at all. Once true the spawn grace stops
    /// applying — the room has shown its hand.
    public private(set) var sawEnemies = false

    /// Consecutive empty observations so far.
    public private(set) var emptyTicks = 0

    /// Observations made, used only to age out the spawn grace.
    public private(set) var ticks = 0

    /// Latched once the room is called clear, so polling again cannot change
    /// the answer.
    public private(set) var cleared = false

    public init(confirmTicks: Int, spawnGraceTicks: Int) {
        self.confirmTicks = confirmTicks
        self.spawnGraceTicks = spawnGraceTicks
    }

    /// Records one observation and reports whether the room is now clear.
    @discardableResult
    public mutating func observe(liveEnemies: Int) -> Bool {
        if cleared { return true }
        ticks += 1

        if liveEnemies > 0 {
            sawEnemies = true
            emptyTicks = 0
            return false
        }

        // Still inside the spawn window with nothing seen yet: the room has not
        // had a chance to populate, so this reading carries no information.
        if !sawEnemies, ticks <= spawnGraceTicks { return false }

        emptyTicks += 1
        if emptyTicks >= confirmTicks { cleared = true }
        return cleared
    }
}
