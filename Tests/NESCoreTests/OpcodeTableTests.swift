import Testing
@testable import NESCore

@Suite("Opcode table")
struct OpcodeTableTests {

    @Test("Table has exactly 256 entries")
    func tableSize() {
        #expect(Opcodes.table.count == 256)
    }

    @Test("Well-known opcodes decode correctly")
    func spotChecks() {
        // A handful of anchors across the table; if the rows ever shift by one
        // these catch it immediately.
        #expect(Opcodes[0x00].mnemonic == .BRK)
        #expect(Opcodes[0xA9].mnemonic == .LDA)
        #expect(Opcodes[0xA9].mode == .immediate)
        #expect(Opcodes[0x20].mnemonic == .JSR)
        #expect(Opcodes[0x20].mode == .absolute)
        #expect(Opcodes[0x60].mnemonic == .RTS)
        #expect(Opcodes[0x4C].mnemonic == .JMP)
        #expect(Opcodes[0x4C].mode == .absolute)
        #expect(Opcodes[0x6C].mnemonic == .JMP)
        #expect(Opcodes[0x6C].mode == .indirect)
        #expect(Opcodes[0xEA].mnemonic == .NOP)
        #expect(Opcodes[0xFF].mnemonic == .ISC)
    }

    @Test("Instruction lengths match addressing modes")
    func lengths() {
        #expect(Opcodes[0xEA].length == 1)   // NOP implied
        #expect(Opcodes[0xA9].length == 2)   // LDA #imm
        #expect(Opcodes[0xAD].length == 3)   // LDA abs
        #expect(Opcodes[0x10].length == 2)   // BPL rel
    }

    @Test("Branch instructions all carry the page-cross penalty")
    func branchPenalties() {
        for opcode: UInt8 in [0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0] {
            let insn = Opcodes[opcode]
            #expect(insn.mode == .relative)
            #expect(insn.pageCrossPenalty)
            #expect(insn.cycles == 2)
        }
    }
}
