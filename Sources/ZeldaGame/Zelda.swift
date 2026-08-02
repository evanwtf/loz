import NESCore

/// The Legend of Zelda (NES, USA revision), SNROM board.
///
/// Decompilation target. Everything specific to this cartridge lives here;
/// `NESCore` stays game-agnostic so another title is a sibling of this file
/// rather than a fork of the emulator.
public enum Zelda: GameDefinition {
    public static let title = "The Legend of Zelda"
    public static let romResourceName = "zelda"
    public static let expectedMapper = 1

    /// SHA-256 of the ROM this project's symbol map and decompiled routines
    /// were derived from. Filled in by `nesrun hash`.
    public static let expectedROMHash =
        "89232edf4f9b52e3cb872094bc78973de080befca2ddea893b6e936066514d4e"

    /// RAM locations recovered so far.
    ///
    /// Found empirically by diffing save states across a known action — walk
    /// one screen east and see which byte changes, take damage and see which
    /// byte drops. That method is reliable and needs no prior knowledge, and it
    /// is how the rest of this map will be filled in.
    public static let symbols = SymbolMap([
        // Link's position within the current screen, in pixels.
        0x0070: "linkPositionX",
        0x0084: "linkPositionY",

        // Facing direction as a bitmask: up = 8, down = 4, left = 2, right = 1.
        0x0098: "linkFacing",

        // Current screen. On the overworld this is (row << 4) | column across
        // a 16x8 grid — Link starts at $77. Inside a dungeon it is the room
        // number instead; Level 1's entrance room is $73.
        0x00EB: "currentScreen",

        // Enemy slots: one byte of type per slot, zero when the slot is empty.
        // Found by clearing a room and looking for a contiguous run that went
        // non-zero to zero, then confirmed across two rooms — three Keese in
        // $72 read `1B 1B 1B`, three Stalfos in $63 read `2A 2A 2A`.
        //
        // This is a better room-clear signal than counting sprites. OAM showed
        // only two of the three Stalfos, because the third had not been drawn
        // yet; the table had all three the whole time.
        0x0350: "enemyTypes",

        // Inventory. Both confirmed with `nesrun ramdiff` against a control run
        // of the same length in which the item was *not* picked up — see
        // docs/agent-harness.md. The sword is 0 = none, 1 = wooden,
        // 2 = white, 3 = magical; keys are a plain count.
        0x0657: "swordLevel",
        0x066E: "keyCount",

        // Health. High nibble is heart containers minus one, low nibble is the
        // count of full hearts remaining.
        0x066F: "linkHealth",
        // Fractional part of the current heart, 0...255.
        0x0670: "linkPartialHeart",

        // Battery-backed save data lives at $6000-$7FFF (three file slots).
        0x6000: "saveSlot0",
        0x6300: "saveSlot1",
        0x6600: "saveSlot2",
    ])

    /// Routines converted to native Swift. Anything not listed here keeps
    /// running interpreted, so the game stays playable throughout.
    ///
    /// Every entry is proven equivalent to its 6502 original by
    /// `RoutineEquivalenceTests` before it is added.
    public static let nativeRoutines = ZeldaRoutines.table()
}
