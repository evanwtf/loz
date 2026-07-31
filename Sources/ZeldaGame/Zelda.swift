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
    /// Zelda keeps most of its live game state in zero page and the $0400-$06FF
    /// block. These are seeds; the map fills in as routines are decompiled and
    /// trace-guided analysis attributes reads and writes to them.
    public static let symbols = SymbolMap([
        // Battery-backed save data lives at $6000-$7FFF (three file slots).
        0x6000: "saveSlot0",
        0x6300: "saveSlot1",
        0x6600: "saveSlot2",
    ])

    /// Routines converted to native Swift. Empty until the first verified
    /// conversion lands; the game runs fully interpreted in the meantime.
    public static let nativeRoutines = RoutineTable()
}
