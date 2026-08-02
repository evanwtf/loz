@testable import NESCore
import Testing

/// The native-routine dispatcher is the spine of incremental decompilation:
/// a registered routine must be indistinguishable from the 6502 it replaces.
@Suite("Native routine dispatch")
struct RoutineDispatchTests {
    /// 32KB NROM image with code planted at the given PRG offsets, reset
    /// vectoring to $8000. Offset 0 corresponds to CPU address $8000.
    private func makeNES(_ blocks: [(offset: Int, bytes: [UInt8])]) throws -> NES {
        var header: [UInt8] = Array("NES\u{1A}".utf8)
        header += [2, 1, 0x00, 0x00]                  // 32KB PRG, 8KB CHR, mapper 0
        header += [UInt8](repeating: 0, count: 8)

        var prg = [UInt8](repeating: 0xEA, count: 0x8000)   // NOP fill
        for block in blocks {
            for (i, byte) in block.bytes.enumerated() { prg[block.offset + i] = byte }
        }
        prg[0x7FFC] = 0x00                            // reset vector -> $8000
        prg[0x7FFD] = 0x80

        let chr = [UInt8](repeating: 0, count: 0x2000)
        return try NES(cartridge: Cartridge(data: header + prg + chr))
    }

    /// `JSR $9000` at $8000; the subroutine at $9000 loads $FF and returns.
    private func makeCallingProgram() throws -> NES {
        try makeNES([
            (offset: 0x0000, bytes: [0x20, 0x00, 0x90]),        // JSR $9000
            (offset: 0x1000, bytes: [0xA9, 0xFF, 0x60]),        // LDA #$FF; RTS
        ])
    }

    @Test("Without a registered routine the interpreter runs the original")
    func interpretedByDefault() throws {
        let nes = try makeCallingProgram()
        nes.step()                       // JSR
        #expect(nes.cpu.pc == 0x9000)
        nes.step()                       // LDA #$FF
        nes.step()                       // RTS
        #expect(nes.cpu.a == 0xFF)
        #expect(nes.cpu.pc == 0x8003)    // returned past the JSR
    }

    @Test("A registered routine runs instead of the 6502 and returns correctly")
    func nativeRoutineReplacesInterpretation() throws {
        let nes = try makeCallingProgram()
        nes.nativeRoutines.register(
            bank: 0, address: 0x9000, name: "loadMagic"
        ) { machine in
            machine.cpu.a = 0x42         // deliberately different from the original
            return 4
        }

        nes.step()                       // JSR
        #expect(nes.cpu.pc == 0x9000)

        nes.step()                       // dispatches natively
        #expect(nes.cpu.a == 0x42, "native body should have run")
        #expect(nes.cpu.pc == 0x8003, "should return as if RTS executed")
        #expect(nes.cpu.sp == 0xFD, "stack must be balanced")
    }

    @Test("Native routines are charged their cycle cost so the PPU stays in sync")
    func cyclesAreCharged() throws {
        let nes = try makeCallingProgram()
        nes.nativeRoutines.register(
            bank: 0, address: 0x9000, name: "costly"
        ) { _ in 100 }

        nes.step()                       // JSR, 6 cycles
        let before = nes.cycles
        let spent = nes.step()
        #expect(spent == 100)
        #expect(nes.cycles == before + 100)
    }

    @Test("Dispatch counts calls, so hot routines are identifiable")
    func callCounting() throws {
        // Loop: JSR $9000; JMP $8000
        let nes = try makeNES([
            (offset: 0x0000, bytes: [0x20, 0x00, 0x90, 0x4C, 0x00, 0x80]),
            (offset: 0x1000, bytes: [0x60]),                     // bare RTS
        ])
        nes.nativeRoutines.register(bank: 0, address: 0x9000, name: "spin") { _ in 6 }

        for _ in 0..<30 { nes.step() }
        let key = RoutineKey(bank: 0, address: 0x9000)
        #expect((nes.nativeCallCounts[key] ?? 0) == 10)
    }

    @Test("Routines are keyed by bank, so the same address differs per bank")
    func routineKeysAreBankScoped() {
        var table = RoutineTable()
        table.register(bank: 0, address: 0x8000, name: "bank0") { _ in 2 }
        table.register(bank: 3, address: 0x8000, name: "bank3") { _ in 2 }

        #expect(table.count == 2)
        #expect(table[RoutineKey(bank: 0, address: 0x8000)]?.name == "bank0")
        #expect(table[RoutineKey(bank: 3, address: 0x8000)]?.name == "bank3")
        #expect(table[RoutineKey(bank: 1, address: 0x8000)] == nil)
    }

    @Test("An empty table leaves the emulator on the pure interpreter path")
    func emptyTableIsInert() throws {
        let nes = try makeCallingProgram()
        #expect(nes.nativeRoutines.isEmpty)
        nes.step(); nes.step(); nes.step()
        #expect(nes.cpu.a == 0xFF)
        #expect(nes.nativeCallCounts.isEmpty)
    }
}
