/// Identifies a routine by bank and CPU address.
///
/// Under a banked mapper an address alone is ambiguous — $8000 means something
/// different in each of Zelda's eight banks — so every routine is keyed by both.
public struct RoutineKey: Hashable, Sendable, CustomStringConvertible {
    public let bank: Int
    public let address: UInt16

    public init(bank: Int, address: UInt16) {
        self.bank = bank
        self.address = address
    }

    public var description: String {
        String(format: "%02X:%04X", bank, address)
    }
}

/// A routine reimplemented in Swift, replacing the interpreted 6502 original.
public struct NativeRoutine: Sendable {
    /// Human-readable name recovered during reverse engineering.
    public let name: String

    /// Runs the routine against live machine state and returns the cycles the
    /// 6502 original would have taken. Implementations read and write CPU
    /// registers and memory exactly as it did, so the caller cannot tell the
    /// difference.
    ///
    /// **The count is returned rather than declared alongside the body.** A
    /// routine with a branch does not have one cost — `00:9C09` takes 31 cycles
    /// when its table entry is non-zero and 15 when it is zero — so a single
    /// number attached to the registration is wrong about half the time, and
    /// there is nowhere honest to put it. Returning it also removes the gap
    /// between what a table says and what the code does, which is where three
    /// wrong declarations had been sitting unnoticed.
    ///
    /// Timing matters even once logic is native, because the PPU is clocked
    /// from the CPU's cycle count — a routine that returned "instantly" would
    /// desynchronise the picture.
    ///
    /// `@Sendable` because routine tables are declared as static game data;
    /// implementations must be pure functions of the machine they are handed
    /// and must not capture external mutable state.
    public let body: @Sendable (NES) -> Int

    public init(name: String, body: @escaping @Sendable (NES) -> Int) {
        self.name = name
        self.body = body
    }
}

/// Maps ROM locations to native Swift implementations.
///
/// This is the spine of the incremental decompilation strategy: the game runs
/// interpreted until a routine is registered here, at which point control
/// transfers to Swift instead. The table grows one verified routine at a time
/// and the game stays playable throughout.
public struct RoutineTable: Sendable {
    private var routines: [RoutineKey: NativeRoutine] = [:]

    public init() {}

    public subscript(key: RoutineKey) -> NativeRoutine? {
        get { routines[key] }
        set { routines[key] = newValue }
    }

    public mutating func register(
        bank: Int,
        address: UInt16,
        name: String,
        body: @escaping @Sendable (NES) -> Int
    ) {
        routines[RoutineKey(bank: bank, address: address)] =
            NativeRoutine(name: name, body: body)
    }

    public var isEmpty: Bool { routines.isEmpty }
    public var count: Int { routines.count }
    public var keys: [RoutineKey] { Array(routines.keys) }

    /// Fraction of a game's known routines that have been converted.
    public func progress(outOf total: Int) -> Double {
        total == 0 ? 0 : Double(routines.count) / Double(total)
    }
}
