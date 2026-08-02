import Foundation
import NESAnalysis
import NESCore
import Testing
@testable import ZeldaGame

/// Proves each decompiled routine is indistinguishable from the 6502 it
/// replaces, across many randomised entry states.
///
/// These tests need the real ROM, which is not committed. They skip cleanly
/// when it is absent so CI stays green without redistributing game data.
@Suite("Decompiled routine equivalence")
struct RoutineEquivalenceTests {
    /// Looks for zelda.nes beside the package.
    private static func locateROM() -> URL? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("zelda.nes"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ZeldaGameTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // package root
                .appendingPathComponent("zelda.nes"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private struct Fixture {
        let cartridge: Cartridge
        let state: SaveState
    }

    /// Boots far enough that RAM holds realistic values rather than zeros.
    private static func makeFixture() throws -> Fixture? {
        guard let url = locateROM() else { return nil }
        let cartridge = try Cartridge(contentsOf: url)
        let nes = try NES(cartridge: cartridge)
        for _ in 0..<120 { nes.stepFrame() }
        return Fixture(cartridge: cartridge, state: nes.captureState())
    }

    private func verify(
        address: UInt16,
        name: String,
        trials: Int = 48
    ) throws {
        guard let fixture = try Self.makeFixture() else {
            // No ROM available; nothing to verify.
            return
        }
        let table = ZeldaRoutines.table()
        guard let routine = table[RoutineKey(bank: 0, address: address)] else {
            Issue.record("no native routine registered at \(name)")
            return
        }

        // Cycle counts are compared too. They were not before, which is how
        // three wrong declarations sat unnoticed — the verifier checks
        // registers, flags and ordered writes, none of which notice timing.
        let failures = try RoutineVerifier.verify(
            cartridge: fixture.cartridge,
            state: fixture.state,
            address: address,
            routine: routine,
            trials: trials,
            checkCycles: true)

        if let first = failures.first {
            let detail = first.discrepancies.map(\.description).joined(separator: "\n    ")
            Issue.record("""
            \(name) diverged on \(failures.count)/\(trials) entry states.
            First failure (A=\(first.entry.a) X=\(first.entry.x) \
            Y=\(first.entry.y) P=\(first.entry.status)):
                \(detail)
            """)
        }
        #expect(failures.isEmpty)
    }

    @Test("resetAudio matches the 6502 original")
    func resetAudioEquivalence() throws {
        try verify(address: 0x9D42, name: "resetAudio")
    }

    @Test("writeMapperControl matches the 6502 original")
    func writeMapperControlEquivalence() throws {
        try verify(address: 0xBF98, name: "writeMapperControl")
    }

    /// The bank-switch register. Of everything converted so far this is the one
    /// with the least forgiving side effect — get it wrong and the wrong code
    /// runs next, which does not look like a routine bug.
    @Test("writeMapperPRGBank matches the 6502 original")
    func writeMapperPRGBankEquivalence() throws {
        try verify(address: 0xBFAC, name: "writeMapperPRGBank")
    }

    @Test("loadPulse1Registers matches the 6502 original")
    func loadPulse1Equivalence() throws {
        try verify(address: 0x9BFF, name: "loadPulse1Registers")
    }

    @Test("loadPulse2Registers matches the 6502 original")
    func loadPulse2Equivalence() throws {
        try verify(address: 0x9C1D, name: "loadPulse2Registers")
    }

    @Test("lookupSoundTableEntry matches the 6502 original")
    func lookupSoundTableEquivalence() throws {
        try verify(address: 0x9EE2, name: "lookupSoundTableEntry")
    }

    /// Rotates through carry and then falls through into the routine above, so
    /// this covers both the rotate semantics and the fall-through.
    @Test("lookupRotatedSoundTableEntry matches the 6502 original")
    func lookupRotatedSoundTableEquivalence() throws {
        try verify(address: 0x9EDC, name: "lookupRotatedSoundTableEntry")
    }

    /// The first converted routine with a branch, and so the first whose cost
    /// is not a constant: 15 cycles when the table entry is zero, 31 when it is
    /// not. With `checkCycles` on, this is what proves a returned count can
    /// track the path actually taken.
    @Test("loadPulse1Frequency matches the 6502 original on both paths")
    func loadPulse1FrequencyEquivalence() throws {
        try verify(address: 0x9C09, name: "loadPulse1Frequency")
    }

    /// Randomised trials pass, but "both paths were covered" should not be
    /// taken on trust — so this drives each one deliberately and asserts the
    /// two costs actually differ. Without a returned cycle count, one of these
    /// two numbers would have to be wrong.
    @Test("The branch in loadPulse1Frequency is charged differently per path")
    func branchCostsDifferPerPath() throws {
        guard let fixture = try Self.makeFixture() else { return }
        let table = ZeldaRoutines.table()
        guard let routine = table[RoutineKey(bank: 0, address: 0x9C09)] else {
            Issue.record("loadPulse1Frequency is not registered")
            return
        }

        func run(forA value: UInt8) throws -> (interpreted: Int, native: Int) {
            let entry = RoutineVerifier.EntryState(a: value, x: 0, y: 0, status: 0x20)
            let interpreted = try RoutineVerifier.runInterpreted(
                cartridge: fixture.cartridge, state: fixture.state,
                address: 0x9C09, entry: entry)
            let native = try RoutineVerifier.runNative(
                cartridge: fixture.cartridge, state: fixture.state,
                routine: routine, entry: entry)
            #expect(RoutineVerifier.compare(
                interpreted: interpreted, native: native).isEmpty)
            return (interpreted.cycles, native.cycles)
        }

        // Which index takes which path is a property of a table in the ROM, so
        // it is discovered by running the interpreter rather than by reading
        // the table here — a separate read would have to force the bank itself,
        // and getting that wrong reads plausible bytes from the wrong bank.
        var earlyExit: Int?
        var fullPath: Int?
        for candidate in UInt8(0)...UInt8(120) {
            let cost = try run(forA: candidate)
            #expect(cost.native == cost.interpreted, "index \(candidate)")
            if cost.native == 15 { earlyExit = cost.native }
            if cost.native == 31 { fullPath = cost.native }
            if earlyExit != nil, fullPath != nil { break }
        }

        #expect(earlyExit == 15, "the zero-entry early exit should cost 15 cycles")
        #expect(fullPath == 31, "the full path should cost 31 cycles")
    }

    @Test("loadNoiseDefaults matches the 6502 original")
    func loadNoiseDefaultsEquivalence() throws {
        try verify(address: 0x9F72, name: "loadNoiseDefaults")
    }

    /// The two pulse loaders write their register pair in opposite orders.
    /// Swapping either would leave identical final memory, so only the ordered
    /// write comparison catches it — this asserts that it does.
    @Test("Swapping the pulse register write order is detected")
    func writeOrderIsChecked() throws {
        guard let fixture = try Self.makeFixture() else { return }

        // loadPulse1Registers with its two stores transposed.
        let swapped = NativeRoutine(name: "swappedPulse1") { nes in
            nes.cpuWrite(0x4000, nes.cpu.x)
            nes.cpuWrite(0x4001, nes.cpu.y)
            return 14
        }

        let failures = try RoutineVerifier.verify(
            cartridge: fixture.cartridge,
            state: fixture.state,
            address: 0x9BFF,
            routine: swapped,
            trials: 8)

        #expect(!failures.isEmpty, "write ordering must be checked")
    }

    /// Guards the harness itself: a deliberately wrong implementation must be
    /// caught. Without this, a verifier that silently passes everything would
    /// look identical to one that works.
    @Test("The verifier rejects a deliberately incorrect implementation")
    func verifierCatchesWrongImplementation() throws {
        guard let fixture = try Self.makeFixture() else { return }

        // Same as resetAudio but collapsed into a single $4015 write — a
        // plausible-looking "simplification" that changes the side effects.
        let broken = NativeRoutine(name: "brokenResetAudio") { nes in
            nes.cpu.a = 0x0F
            nes.cpu.setZeroNegative(0x0F)
            nes.cpuWrite(0x0609, 0x00)
            nes.cpuWrite(0x4015, 0x0F)
            return 22
        }

        let failures = try RoutineVerifier.verify(
            cartridge: fixture.cartridge,
            state: fixture.state,
            address: 0x9D42,
            routine: broken,
            trials: 4)

        #expect(!failures.isEmpty, "verifier failed to catch a wrong implementation")
    }
}
