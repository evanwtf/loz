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

        let failures = try RoutineVerifier.verify(
            cartridge: fixture.cartridge,
            state: fixture.state,
            address: address,
            routine: routine,
            trials: trials)

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

    @Test("writeMapperRegister matches the 6502 original")
    func writeMapperRegisterEquivalence() throws {
        try verify(address: 0xBF98, name: "writeMapperRegister")
    }

    /// Guards the harness itself: a deliberately wrong implementation must be
    /// caught. Without this, a verifier that silently passes everything would
    /// look identical to one that works.
    @Test("The verifier rejects a deliberately incorrect implementation")
    func verifierCatchesWrongImplementation() throws {
        guard let fixture = try Self.makeFixture() else { return }

        // Same as resetAudio but collapsed into a single $4015 write — a
        // plausible-looking "simplification" that changes the side effects.
        let broken = NativeRoutine(name: "brokenResetAudio", cycles: 20) { nes in
            nes.cpu.a = 0x0F
            nes.cpu.setZeroNegative(0x0F)
            nes.cpuWrite(0x0609, 0x00)
            nes.cpuWrite(0x4015, 0x0F)
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
