import Foundation
@testable import NESCore
import Testing

/// Save states must restore the machine *exactly*. A snapshot that is subtly
/// wrong produces a game that looks fine and then desynchronises later, which
/// is far worse than one that fails loudly.
@Suite("Save states")
struct SaveStateTests {
    /// A cartridge with CHR-RAM and battery RAM, so the snapshot has to carry
    /// both — matching Zelda's board.
    private func makeNES() throws -> NES {
        var header: [UInt8] = Array("NES\u{1A}".utf8)
        header += [2, 0, 0x02, 0x00]           // 32KB PRG, CHR-RAM, battery, mapper 0
        header += [UInt8](repeating: 0, count: 8)

        var prg = [UInt8](repeating: 0xEA, count: 0x8000)
        // A loop that keeps the CPU busy: INC $00; JMP $8000
        prg[0x0000] = 0xE6; prg[0x0001] = 0x00
        prg[0x0002] = 0x4C; prg[0x0003] = 0x00; prg[0x0004] = 0x80
        prg[0x7FFC] = 0x00; prg[0x7FFD] = 0x80

        return try NES(cartridge: Cartridge(data: header + prg))
    }

    @Test("Capture and restore round-trips the full machine")
    func roundTrip() throws {
        let nes = try makeNES()
        for _ in 0..<5 { nes.stepFrame() }

        // Dirty every region the snapshot is meant to cover.
        nes.cpuWrite(0x0123, 0xAB)
        nes.cartridge.prgRAM[0x0010] = 0xCD
        nes.ppu.ppuWrite(0x0100, 0x5A)         // CHR-RAM
        nes.ppu.ppuWrite(0x2001, 0x77)         // nametable
        nes.ppu.ppuWrite(0x3F03, 0x21)         // palette
        nes.ppu.oam[7] = 0x42

        let snapshot = nes.captureState()
        let expected = (
            a: nes.cpu.a, x: nes.cpu.x, y: nes.cpu.y,
            sp: nes.cpu.sp, pc: nes.cpu.pc, status: nes.cpu.status,
            cycles: nes.cycles, scanline: nes.ppu.scanline, dot: nes.ppu.dot)

        // Run on, so restoring has to actually undo something.
        for _ in 0..<10 { nes.stepFrame() }
        #expect(nes.cpu.pc != expected.pc || nes.cycles != expected.cycles)

        try nes.restoreState(snapshot)

        #expect(nes.cpu.a == expected.a)
        #expect(nes.cpu.x == expected.x)
        #expect(nes.cpu.y == expected.y)
        #expect(nes.cpu.sp == expected.sp)
        #expect(nes.cpu.pc == expected.pc)
        #expect(nes.cpu.status == expected.status)
        #expect(nes.cycles == expected.cycles)
        #expect(nes.ppu.scanline == expected.scanline)
        #expect(nes.ppu.dot == expected.dot)

        #expect(nes.cpuRead(0x0123) == 0xAB)
        #expect(nes.cartridge.prgRAM[0x0010] == 0xCD)
        #expect(nes.ppu.ppuRead(0x0100) == 0x5A)
        #expect(nes.ppu.ppuRead(0x2001) == 0x77)
        #expect(nes.ppu.ppuRead(0x3F03) == 0x21)
        #expect(nes.ppu.oam[7] == 0x42)
    }

    /// The real test of a snapshot: two machines restored to the same state
    /// must then diverge identically, not merely look alike at rest.
    @Test("Restored machines stay in lockstep afterwards")
    func deterministicAfterRestore() throws {
        let original = try makeNES()
        for _ in 0..<8 { original.stepFrame() }
        let snapshot = original.captureState()

        for _ in 0..<20 { original.stepFrame() }
        let reference = original.captureState()

        let restored = try makeNES()
        try restored.restoreState(snapshot)
        for _ in 0..<20 { restored.stepFrame() }
        let replayed = restored.captureState()

        #expect(replayed.cpu.pc == reference.cpu.pc)
        #expect(replayed.cpu.a == reference.cpu.a)
        #expect(replayed.cycles == reference.cycles)
        #expect(replayed.ram == reference.ram)
        #expect(replayed.ppu.vram == reference.ppu.vram)
        #expect(replayed.ppu.oam == reference.ppu.oam)
    }

    @Test("Snapshots survive JSON encoding, which is how they reach disk")
    func codableRoundTrip() throws {
        let nes = try makeNES()
        for _ in 0..<3 { nes.stepFrame() }
        nes.cpuWrite(0x0200, 0x99)

        let encoded = try JSONEncoder().encode(nes.captureState(romHash: "abc123"))
        let decoded = try JSONDecoder().decode(SaveState.self, from: encoded)

        let fresh = try makeNES()
        try fresh.restoreState(decoded, romHash: "abc123")
        #expect(fresh.cpuRead(0x0200) == 0x99)
    }

    @Test("A snapshot from a different ROM is refused")
    func rejectsMismatchedROM() throws {
        let nes = try makeNES()
        let snapshot = nes.captureState(romHash: "aaaa")

        #expect(throws: SaveStateError.self) {
            try nes.restoreState(snapshot, romHash: "bbbb")
        }
    }

    @Test("An unknown version is refused rather than misread")
    func rejectsFutureVersion() throws {
        let nes = try makeNES()
        var snapshot = nes.captureState()
        snapshot.version = 99

        #expect(throws: SaveStateError.self) {
            try nes.restoreState(snapshot)
        }
    }

    @Test("Mapper banking is part of the snapshot")
    func mapperStateRestored() throws {
        // MMC1 cartridge: 128KB PRG so banking is observable.
        var header: [UInt8] = Array("NES\u{1A}".utf8)
        header += [8, 0, 0x12, 0x00]           // mapper 1, battery, CHR-RAM
        header += [UInt8](repeating: 0, count: 8)

        var prg = [UInt8](repeating: 0xEA, count: 0x20000)
        // Tag each bank so the mapped bank is identifiable by reading $8000.
        for bank in 0..<8 { prg[bank * 0x4000] = UInt8(0xB0 + bank) }
        prg[0x1FFFC] = 0x00; prg[0x1FFFD] = 0x80

        let nes = try NES(cartridge: Cartridge(data: header + prg))

        // Serially shift bank 3 into the PRG bank register at $E000.
        for bit in 0..<5 {
            nes.cpuWrite(0xE000, UInt8((3 >> bit) & 1))
        }
        let bankedValue = nes.cpuRead(0x8000)
        #expect(bankedValue == 0xB3, "expected bank 3 to be mapped")

        let snapshot = nes.captureState()

        // Switch to a different bank, then restore.
        for bit in 0..<5 {
            nes.cpuWrite(0xE000, UInt8((6 >> bit) & 1))
        }
        #expect(nes.cpuRead(0x8000) == 0xB6)

        try nes.restoreState(snapshot)
        #expect(nes.cpuRead(0x8000) == 0xB3, "banking must be restored")
    }
}
