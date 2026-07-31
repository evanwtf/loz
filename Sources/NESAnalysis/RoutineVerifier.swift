import Foundation
import NESCore

/// Proves a decompiled Swift routine behaves identically to the 6502 it
/// replaces.
///
/// Without this, decompilation is guesswork: a routine can look right, run
/// without crashing, and still corrupt state in a way that only surfaces
/// hours of gameplay later. With it, every conversion is mechanically checked
/// against the interpreter on real machine states.
///
/// Comparing final memory is not sufficient. PPU and APU registers are
/// order-sensitive — writing scroll then address behaves differently from the
/// reverse — so the *sequence* of writes is compared too.
public enum RoutineVerifier {
    /// Where a routine "returns to". Chosen in RAM, far from any real code, so
    /// execution never actually reaches it.
    public static let sentinel: UInt16 = 0x0002

    public struct Outcome {
        public var a: UInt8 = 0
        public var x: UInt8 = 0
        public var y: UInt8 = 0
        public var sp: UInt8 = 0
        public var status: UInt8 = 0
        public var cycles = 0
        /// Every CPU write in order, excluding stack traffic which is an
        /// implementation detail of how the routine was invoked.
        public var writes: [(address: UInt16, value: UInt8)] = []
        public var ram: [UInt8] = []
        /// False if the routine ran away and hit the instruction cap.
        public var completed = false
    }

    public struct Discrepancy: CustomStringConvertible {
        public let field: String
        public let interpreted: String
        public let native: String

        public var description: String {
            "\(field): interpreted \(interpreted), native \(native)"
        }
    }

    /// Randomised entry conditions, so a conversion is not merely correct for
    /// one convenient input.
    public struct EntryState {
        public var a: UInt8
        public var x: UInt8
        public var y: UInt8
        public var status: UInt8

        public init(a: UInt8, x: UInt8, y: UInt8, status: UInt8) {
            self.a = a
            self.x = x
            self.y = y
            self.status = status
        }

        public static func random(using generator: inout some RandomNumberGenerator) -> EntryState {
            EntryState(
                a: UInt8.random(in: 0...255, using: &generator),
                x: UInt8.random(in: 0...255, using: &generator),
                y: UInt8.random(in: 0...255, using: &generator),
                // Keep the unused bit set and the break bit clear, as hardware
                // does; randomise the rest.
                status: (UInt8.random(in: 0...255, using: &generator) & 0xCF) | 0x20)
        }
    }

    // MARK: Execution

    /// Forces a PRG bank to be mapped at $8000.
    ///
    /// A routine is identified by (bank, address), but a restored save state
    /// has whatever bank happened to be live when it was captured. Without
    /// this, verification executes whatever bytes are at that address in the
    /// wrong bank — which is not the routine at all.
    private static func forceBank(_ nes: NES, _ bank: Int) {
        var mapperState = nes.mapper.persistentState
        guard mapperState.count == 5 else { return }   // MMC1 layout
        mapperState[1] = (mapperState[1] & ~0x0C) | 0x0C   // PRG mode 3
        mapperState[4] = UInt8(bank & 0x0F)
        nes.mapper.persistentState = mapperState
    }

    /// Runs the interpreted 6502 routine at `address` and reports its effects.
    public static func runInterpreted(
        cartridge: Cartridge,
        state: SaveState,
        address: UInt16,
        bank: Int = 0,
        entry: EntryState,
        maxInstructions: Int = 500_000
    ) throws -> Outcome {
        let nes = try NES(cartridge: cartridge)
        try nes.restoreState(state)
        forceBank(nes, bank)
        applyEntry(entry, to: nes)

        var outcome = Outcome()
        var writes: [(UInt16, UInt8)] = []
        nes.onMemoryWrite = { addressWritten, value in
            // Stack writes belong to the call mechanism, not the routine.
            guard !(0x0100...0x01FF).contains(addressWritten) else { return }
            writes.append((addressWritten, value))
        }

        let startCycles = nes.cpu.totalCycles
        nes.cpu.enterSubroutine(at: address, returningTo: sentinel)

        var executed = 0
        while nes.cpu.pc != sentinel, executed < maxInstructions {
            // Step the CPU alone rather than the whole machine. Clocking the
            // PPU would let an NMI fire mid-routine and run the game's entire
            // frame handler, which has nothing to do with the routine under
            // test and swamps its effects.
            nes.cpu.step()
            executed += 1
        }
        outcome.completed = nes.cpu.pc == sentinel
        outcome.cycles = nes.cpu.totalCycles - startCycles

        nes.onMemoryWrite = nil
        capture(&outcome, from: nes, writes: writes)
        return outcome
    }

    /// Runs a native Swift implementation against the same starting state.
    public static func runNative(
        cartridge: Cartridge,
        state: SaveState,
        routine: NativeRoutine,
        bank: Int = 0,
        entry: EntryState
    ) throws -> Outcome {
        let nes = try NES(cartridge: cartridge)
        try nes.restoreState(state)
        forceBank(nes, bank)
        applyEntry(entry, to: nes)

        var outcome = Outcome()
        var writes: [(UInt16, UInt8)] = []
        nes.onMemoryWrite = { addressWritten, value in
            guard !(0x0100...0x01FF).contains(addressWritten) else { return }
            writes.append((addressWritten, value))
        }

        nes.cpu.enterSubroutine(at: 0xFFFF, returningTo: sentinel)
        routine.body(nes)
        nes.cpu.returnFromSubroutine()

        outcome.completed = nes.cpu.pc == sentinel
        outcome.cycles = routine.cycles

        nes.onMemoryWrite = nil
        capture(&outcome, from: nes, writes: writes)
        return outcome
    }

    private static func applyEntry(_ entry: EntryState, to nes: NES) {
        nes.cpu.a = entry.a
        nes.cpu.x = entry.x
        nes.cpu.y = entry.y
        nes.cpu.status = entry.status
    }

    private static func capture(
        _ outcome: inout Outcome,
        from nes: NES,
        writes: [(UInt16, UInt8)]
    ) {
        outcome.a = nes.cpu.a
        outcome.x = nes.cpu.x
        outcome.y = nes.cpu.y
        outcome.sp = nes.cpu.sp
        outcome.status = nes.cpu.status
        outcome.writes = writes.map { (address: $0.0, value: $0.1) }
        outcome.ram = nes.ram
    }

    // MARK: Comparison

    /// Lists every way the two runs differed. Empty means equivalent.
    public static func compare(
        interpreted: Outcome,
        native: Outcome,
        checkCycles: Bool = true
    ) -> [Discrepancy] {
        var found: [Discrepancy] = []

        func check(_ field: String, _ lhs: some Equatable & CustomStringConvertible,
                   _ rhs: some Equatable & CustomStringConvertible)
        {
            if "\(lhs)" != "\(rhs)" {
                found.append(Discrepancy(field: field,
                                         interpreted: "\(lhs)", native: "\(rhs)"))
            }
        }

        check("A", hex(interpreted.a), hex(native.a))
        check("X", hex(interpreted.x), hex(native.x))
        check("Y", hex(interpreted.y), hex(native.y))
        check("SP", hex(interpreted.sp), hex(native.sp))
        check("status", flags(interpreted.status), flags(native.status))

        if !interpreted.completed || !native.completed {
            found.append(Discrepancy(
                field: "completed",
                interpreted: "\(interpreted.completed)", native: "\(native.completed)"))
        }

        // RAM deltas.
        if interpreted.ram.count == native.ram.count {
            for index in 0..<interpreted.ram.count
                where interpreted.ram[index] != native.ram[index]
            {
                found.append(Discrepancy(
                    field: String(format: "RAM $%04X", index),
                    interpreted: hex(interpreted.ram[index]),
                    native: hex(native.ram[index])))
                if found.count > 24 { break }   // enough to diagnose
            }
        }

        // Ordered side effects.
        if interpreted.writes.count != native.writes.count {
            check("write count", interpreted.writes.count, native.writes.count)
        } else {
            for (index, pair) in zip(interpreted.writes, native.writes).enumerated() {
                if pair.0.address != pair.1.address || pair.0.value != pair.1.value {
                    found.append(Discrepancy(
                        field: "write #\(index)",
                        interpreted: String(format: "$%04X<-%02X", pair.0.address, pair.0.value),
                        native: String(format: "$%04X<-%02X", pair.1.address, pair.1.value)))
                }
            }
        }

        if checkCycles {
            check("cycles", interpreted.cycles, native.cycles)
        }
        return found
    }

    private static func hex(_ value: UInt8) -> String {
        String(format: "$%02X", value)
    }

    /// Renders the status register as flag letters, which is far easier to
    /// diagnose than a hex byte.
    private static func flags(_ status: UInt8) -> String {
        let names: [(UInt8, Character)] = [
            (0x80, "N"), (0x40, "V"), (0x08, "D"),
            (0x04, "I"), (0x02, "Z"), (0x01, "C"),
        ]
        let set = names.map { status & $0.0 != 0 ? String($0.1) : "-" }
        return set.joined()
    }

    // MARK: Convenience

    /// Verifies a routine across many randomised entry states.
    ///
    /// Randomisation matters: a conversion that only handles the register
    /// values it happened to be tested with will pass a single check and fail
    /// in play.
    public static func verify(
        cartridge: Cartridge,
        state: SaveState,
        address: UInt16,
        bank: Int = 0,
        routine: NativeRoutine,
        trials: Int = 32,
        seed: UInt64 = 0x5EED,
        checkCycles: Bool = false
    ) throws -> [(entry: EntryState, discrepancies: [Discrepancy])] {
        var generator = SeededGenerator(seed: seed)
        var failures: [(EntryState, [Discrepancy])] = []

        for _ in 0..<trials {
            let entry = EntryState.random(using: &generator)
            let interpreted = try runInterpreted(
                cartridge: cartridge, state: state, address: address,
                bank: bank, entry: entry)
            let native = try runNative(
                cartridge: cartridge, state: state, routine: routine,
                bank: bank, entry: entry)

            let differences = compare(
                interpreted: interpreted, native: native, checkCycles: checkCycles)
            if !differences.isEmpty {
                failures.append((entry, differences))
            }
        }
        return failures
    }
}

/// Deterministic RNG so a failing verification can be reproduced exactly.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
