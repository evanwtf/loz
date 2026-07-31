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

        // Current screen. On the overworld this is (row << 4) | column across
        // a 16x8 grid — Link starts at $77. Inside a dungeon it is the room
        // number instead; Level 1's entrance room is $73.
        0x00EB: "currentScreen",

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

    /// Routines converted to native Swift. Empty until the first verified
    /// conversion lands; the game runs fully interpreted in the meantime.
    public static let nativeRoutines = RoutineTable()
}
