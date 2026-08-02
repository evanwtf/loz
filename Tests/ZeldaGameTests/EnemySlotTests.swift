import Testing
import ZeldaGame

/// The enemy slot table is the room-clear signal, so what counts as "a live
/// enemy" has to be exact in both directions. Counting too few ends a fight
/// early; counting too many hangs the loop forever on something that cannot be
/// killed. Both failures were observed on the real game before this existed.
@Suite("Zelda enemy slots")
struct EnemySlotTests {
    /// A reader over a sparse RAM image, so a test states only the bytes it
    /// cares about and everything else reads as an empty slot.
    private func ram(_ bytes: [UInt16: UInt8]) -> (UInt16) -> UInt8 {
        { bytes[$0] ?? 0 }
    }

    @Test("An empty table has no live enemies")
    func emptyTable() {
        #expect(Zelda.liveEnemyCount(ram([:])) == 0)
        #expect(Zelda.liveEnemyTypes(ram([:])).isEmpty)
    }

    /// Room $72 of Level 1, measured: three Keese read `1B 1B 1B`.
    @Test("Three Keese in room $72 count as three")
    func threeKeese() {
        let keese = ram([0x0350: 0x1B, 0x0351: 0x1B, 0x0352: 0x1B])
        #expect(Zelda.liveEnemyCount(keese) == 3)
        #expect(Zelda.liveEnemyTypes(keese) == [0x1B, 0x1B, 0x1B])
    }

    /// Room $63, measured: three Stalfos read `2A 2A 2A`. This is the case that
    /// motivated the whole change — OAM reported only two of them, because the
    /// third had not been drawn yet, and the room was declared clear early.
    @Test("Three Stalfos in room $63 count as three even when one is undrawn")
    func threeStalfos() {
        #expect(Zelda.liveEnemyCount(ram([0x0350: 0x2A, 0x0351: 0x2A, 0x0352: 0x2A])) == 3)
    }

    /// Killing the middle one of three leaves a hole rather than compacting the
    /// table, so counting must not stop at the first zero.
    @Test("A hole left by a kill does not truncate the count")
    func holeInTheMiddle() {
        let holed = ram([0x0350: 0x2A, 0x0352: 0x2A])
        #expect(Zelda.liveEnemyCount(holed) == 2)
        #expect(Zelda.liveEnemyTypes(holed) == [0x2A, 0x2A])
    }

    /// The high object slots hold things that are not enemies. Measured on
    /// overworld screen $67: two Octorok rocks in flight sit at `$0358`/`$0359`
    /// and a further object at `$035A`. Counting those would mean the loop
    /// never terminates on any screen with a projectile in the air.
    @Test("Projectiles in the high object slots are not enemies")
    func projectilesAreNotEnemies() {
        let inFlight = ram([0x0358: 0x53, 0x0359: 0x53, 0x035A: 0x63])
        #expect(Zelda.liveEnemyCount(inFlight) == 0)
    }

    /// `$035F` mirrors the room's enemy type and — measured — survives the room
    /// being cleared, so it is not a slot. Room $72 after the Keese are dead
    /// reads all slots zero with `$035F = 1B` still set.
    @Test("The type mirror at $035F survives a clear and is not counted")
    func typeMirrorIsNotASlot() {
        #expect(Zelda.liveEnemyCount(ram([0x035F: 0x1B])) == 0)
    }

    @Test("Enemies coexisting with projectiles count only the enemies")
    func enemiesAndProjectiles() {
        let mixed = ram([
            0x0350: 0x07, 0x0351: 0x07, 0x0352: 0x07, 0x0353: 0x07,
            0x0358: 0x53, 0x0359: 0x53, 0x035A: 0x63, 0x035F: 0x07,
        ])
        #expect(Zelda.liveEnemyCount(mixed) == 4)
    }

    /// Six is the most the game spawns, and the slot range has to hold all of
    /// them — a window one short would silently drop the last enemy.
    @Test("A full table of six is counted")
    func fullTable() {
        var full: [UInt16: UInt8] = [:]
        for slot in Zelda.enemySlots { full[slot] = 0x07 }
        #expect(Zelda.enemySlots.count == 6)
        #expect(Zelda.liveEnemyCount(ram(full)) == 6)
    }

    @Test("The slot range starts at the documented enemyTypes symbol")
    func rangeMatchesSymbolMap() {
        #expect(Zelda.enemySlots.lowerBound == 0x0350)
        #expect(Zelda.symbols[Zelda.enemySlots.lowerBound] == "enemyTypes")
    }
}

/// The symbol map is the project's record of what has actually been established
/// about this cartridge's RAM, so the things it claims should be asserted rather
/// than left as comments.
@Suite("Zelda symbol map")
struct SymbolMapTests {
    @Test("Every symbol recovered so far is present under its measured address")
    func knownSymbols() {
        let expected: [UInt16: String] = [
            0x0070: "linkPositionX",
            0x0084: "linkPositionY",
            0x0098: "linkFacing",
            0x00EB: "currentScreen",
            0x0350: "enemyTypes",
            0x0657: "swordLevel",
            0x0658: "bombCount",
            0x0664: "magicalKey",
            0x066D: "rupeeCount",
            0x066E: "keyCount",
            0x066F: "linkHealth",
            0x0670: "linkPartialHeart",
            0x067D: "rupeesPending",
        ]
        for (address, name) in expected {
            #expect(Zelda.symbols[address] == name, "at \(String(address, radix: 16))")
        }
    }

    /// The save slots are 0x300 apart, which is what makes them three slots
    /// rather than one region that happens to have three names.
    @Test("The three battery save slots are evenly spaced in PRG RAM")
    func saveSlots() {
        #expect(Zelda.symbols[0x6000] == "saveSlot0")
        #expect(Zelda.symbols[0x6300] == "saveSlot1")
        #expect(Zelda.symbols[0x6600] == "saveSlot2")
    }

    @Test("An address nothing is known about has no name")
    func unknownAddress() {
        #expect(Zelda.symbols[0x1234] == nil)
    }
}
