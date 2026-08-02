import NESCore

// The enemy slot table, and what counts as a live enemy in it.
//
// This is the room-clear signal. It replaced counting sprites in OAM, which
// undercounts: in room $63 OAM showed two Stalfos while the table held three,
// because the third had not been drawn yet. The table is populated when the
// game commits an enemy to a slot, which happens before anything reaches the
// screen.
public extension Zelda {
    /// Enemy object slots, one type byte each; zero means the slot is empty.
    ///
    /// Six, because that is the most the game spawns at once. The bound matters
    /// in both directions and was established by observation, not assumption:
    ///
    /// - **Not shorter.** Four enemies at `$0350-$0353` were measured on
    ///   overworld screens `$66`, `$67`, `$68`, `$76` and `$78`, so a window of
    ///   three or four would drop live enemies.
    /// - **Not longer.** The object array continues past the enemies and holds
    ///   things that cannot be killed. Screen `$67` puts two Octorok rocks in
    ///   flight at `$0358`/`$0359` and a further object at `$035A`; a window
    ///   that reached them would mean the room-clearing loop never terminated
    ///   while a projectile was in the air.
    ///
    /// `$035F` is not part of the array at all. It mirrors the room's enemy
    /// type and survives the room being cleared — room `$72` with every Keese
    /// dead reads all slots zero and `$035F = 1B`.
    static let enemySlots: ClosedRange<UInt16> = 0x0350...0x0355

    /// How many enemy slots are occupied.
    ///
    /// Every slot in the range is examined rather than stopping at the first
    /// zero: killing the middle of three leaves a hole instead of compacting
    /// the table, and an early stop would report one enemy where two remain.
    static func liveEnemyCount(_ read: (UInt16) -> UInt8) -> Int {
        enemySlots.reduce(0) { $0 + (read($1) == 0 ? 0 : 1) }
    }

    /// The type byte of each occupied slot, in slot order. Useful for telling
    /// one room from another in a log — three Keese read `1B 1B 1B`, three
    /// Stalfos `2A 2A 2A`.
    static func liveEnemyTypes(_ read: (UInt16) -> UInt8) -> [UInt8] {
        enemySlots.map(read).filter { $0 != 0 }
    }

    /// Convenience over a running machine.
    static func liveEnemyCount(in nes: NES) -> Int {
        liveEnemyCount { nes.cpuRead($0) }
    }

    /// Convenience over a running machine.
    static func liveEnemyTypes(in nes: NES) -> [UInt8] {
        liveEnemyTypes { nes.cpuRead($0) }
    }
}
