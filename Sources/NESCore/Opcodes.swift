/// 6502 addressing modes.
public enum AddressingMode: UInt8, Sendable {
    case implied, accumulator, immediate
    case zeroPage, zeroPageX, zeroPageY
    case relative
    case absolute, absoluteX, absoluteY
    case indirect, indexedIndirect, indirectIndexed

    /// Total instruction length in bytes, including the opcode.
    public var instructionLength: Int {
        switch self {
        case .implied, .accumulator: return 1
        case .immediate, .zeroPage, .zeroPageX, .zeroPageY,
             .relative, .indexedIndirect, .indirectIndexed: return 2
        case .absolute, .absoluteX, .absoluteY, .indirect: return 3
        }
    }
}

/// Instruction mnemonics. Includes the undocumented opcodes: the disassembler
/// needs them to avoid desyncing on data misread as code, and a few games
/// genuinely rely on them.
public enum Mnemonic: String, Sendable {
    // Official
    case ADC, AND, ASL, BCC, BCS, BEQ, BIT, BMI, BNE, BPL, BRK, BVC, BVS
    case CLC, CLD, CLI, CLV, CMP, CPX, CPY, DEC, DEX, DEY, EOR, INC, INX, INY
    case JMP, JSR, LDA, LDX, LDY, LSR, NOP, ORA, PHA, PHP, PLA, PLP
    case ROL, ROR, RTI, RTS, SBC, SEC, SED, SEI, STA, STX, STY
    case TAX, TAY, TSX, TXA, TXS, TYA
    // Undocumented
    case AHX, ALR, ANC, ARR, AXS, DCP, ISC, KIL, LAS, LAX, RLA, RRA
    case SAX, SHX, SHY, SLO, SRE, TAS, XAA

    /// True for the undocumented set, so listings can flag them.
    public var isUndocumented: Bool {
        switch self {
        case .AHX, .ALR, .ANC, .ARR, .AXS, .DCP, .ISC, .KIL, .LAS, .LAX,
             .RLA, .RRA, .SAX, .SHX, .SHY, .SLO, .SRE, .TAS, .XAA:
            return true
        default:
            return false
        }
    }
}

public struct Instruction: Sendable {
    public let mnemonic: Mnemonic
    public let mode: AddressingMode
    /// Base cycle count, before any page-crossing or branch-taken penalty.
    public let cycles: Int
    /// Whether crossing a page boundary during indexing costs an extra cycle.
    public let pageCrossPenalty: Bool

    public var length: Int { mode.instructionLength }
}

public enum Opcodes {
    /// The full 256-entry opcode table, indexed by opcode byte.
    public static let table: [Instruction] = {
        // Compact spelling: (mnemonic, mode, cycles, pageCrossPenalty)
        typealias E = (Mnemonic, AddressingMode, Int, Bool)
        let imp = AddressingMode.implied, acc = AddressingMode.accumulator
        let imm = AddressingMode.immediate, rel = AddressingMode.relative
        let zp = AddressingMode.zeroPage, zpx = AddressingMode.zeroPageX
        let zpy = AddressingMode.zeroPageY, ind = AddressingMode.indirect
        let abs = AddressingMode.absolute, abx = AddressingMode.absoluteX
        let aby = AddressingMode.absoluteY
        let izx = AddressingMode.indexedIndirect, izy = AddressingMode.indirectIndexed

        let e: [E] = [
            // 0x00
            (.BRK, imp, 7, false), (.ORA, izx, 6, false), (.KIL, imp, 2, false), (.SLO, izx, 8, false),
            (.NOP, zp,  3, false), (.ORA, zp,  3, false), (.ASL, zp,  5, false), (.SLO, zp,  5, false),
            (.PHP, imp, 3, false), (.ORA, imm, 2, false), (.ASL, acc, 2, false), (.ANC, imm, 2, false),
            (.NOP, abs, 4, false), (.ORA, abs, 4, false), (.ASL, abs, 6, false), (.SLO, abs, 6, false),
            // 0x10
            (.BPL, rel, 2, true ), (.ORA, izy, 5, true ), (.KIL, imp, 2, false), (.SLO, izy, 8, false),
            (.NOP, zpx, 4, false), (.ORA, zpx, 4, false), (.ASL, zpx, 6, false), (.SLO, zpx, 6, false),
            (.CLC, imp, 2, false), (.ORA, aby, 4, true ), (.NOP, imp, 2, false), (.SLO, aby, 7, false),
            (.NOP, abx, 4, true ), (.ORA, abx, 4, true ), (.ASL, abx, 7, false), (.SLO, abx, 7, false),
            // 0x20
            (.JSR, abs, 6, false), (.AND, izx, 6, false), (.KIL, imp, 2, false), (.RLA, izx, 8, false),
            (.BIT, zp,  3, false), (.AND, zp,  3, false), (.ROL, zp,  5, false), (.RLA, zp,  5, false),
            (.PLP, imp, 4, false), (.AND, imm, 2, false), (.ROL, acc, 2, false), (.ANC, imm, 2, false),
            (.BIT, abs, 4, false), (.AND, abs, 4, false), (.ROL, abs, 6, false), (.RLA, abs, 6, false),
            // 0x30
            (.BMI, rel, 2, true ), (.AND, izy, 5, true ), (.KIL, imp, 2, false), (.RLA, izy, 8, false),
            (.NOP, zpx, 4, false), (.AND, zpx, 4, false), (.ROL, zpx, 6, false), (.RLA, zpx, 6, false),
            (.SEC, imp, 2, false), (.AND, aby, 4, true ), (.NOP, imp, 2, false), (.RLA, aby, 7, false),
            (.NOP, abx, 4, true ), (.AND, abx, 4, true ), (.ROL, abx, 7, false), (.RLA, abx, 7, false),
            // 0x40
            (.RTI, imp, 6, false), (.EOR, izx, 6, false), (.KIL, imp, 2, false), (.SRE, izx, 8, false),
            (.NOP, zp,  3, false), (.EOR, zp,  3, false), (.LSR, zp,  5, false), (.SRE, zp,  5, false),
            (.PHA, imp, 3, false), (.EOR, imm, 2, false), (.LSR, acc, 2, false), (.ALR, imm, 2, false),
            (.JMP, abs, 3, false), (.EOR, abs, 4, false), (.LSR, abs, 6, false), (.SRE, abs, 6, false),
            // 0x50
            (.BVC, rel, 2, true ), (.EOR, izy, 5, true ), (.KIL, imp, 2, false), (.SRE, izy, 8, false),
            (.NOP, zpx, 4, false), (.EOR, zpx, 4, false), (.LSR, zpx, 6, false), (.SRE, zpx, 6, false),
            (.CLI, imp, 2, false), (.EOR, aby, 4, true ), (.NOP, imp, 2, false), (.SRE, aby, 7, false),
            (.NOP, abx, 4, true ), (.EOR, abx, 4, true ), (.LSR, abx, 7, false), (.SRE, abx, 7, false),
            // 0x60
            (.RTS, imp, 6, false), (.ADC, izx, 6, false), (.KIL, imp, 2, false), (.RRA, izx, 8, false),
            (.NOP, zp,  3, false), (.ADC, zp,  3, false), (.ROR, zp,  5, false), (.RRA, zp,  5, false),
            (.PLA, imp, 4, false), (.ADC, imm, 2, false), (.ROR, acc, 2, false), (.ARR, imm, 2, false),
            (.JMP, ind, 5, false), (.ADC, abs, 4, false), (.ROR, abs, 6, false), (.RRA, abs, 6, false),
            // 0x70
            (.BVS, rel, 2, true ), (.ADC, izy, 5, true ), (.KIL, imp, 2, false), (.RRA, izy, 8, false),
            (.NOP, zpx, 4, false), (.ADC, zpx, 4, false), (.ROR, zpx, 6, false), (.RRA, zpx, 6, false),
            (.SEI, imp, 2, false), (.ADC, aby, 4, true ), (.NOP, imp, 2, false), (.RRA, aby, 7, false),
            (.NOP, abx, 4, true ), (.ADC, abx, 4, true ), (.ROR, abx, 7, false), (.RRA, abx, 7, false),
            // 0x80
            (.NOP, imm, 2, false), (.STA, izx, 6, false), (.NOP, imm, 2, false), (.SAX, izx, 6, false),
            (.STY, zp,  3, false), (.STA, zp,  3, false), (.STX, zp,  3, false), (.SAX, zp,  3, false),
            (.DEY, imp, 2, false), (.NOP, imm, 2, false), (.TXA, imp, 2, false), (.XAA, imm, 2, false),
            (.STY, abs, 4, false), (.STA, abs, 4, false), (.STX, abs, 4, false), (.SAX, abs, 4, false),
            // 0x90
            (.BCC, rel, 2, true ), (.STA, izy, 6, false), (.KIL, imp, 2, false), (.AHX, izy, 6, false),
            (.STY, zpx, 4, false), (.STA, zpx, 4, false), (.STX, zpy, 4, false), (.SAX, zpy, 4, false),
            (.TYA, imp, 2, false), (.STA, aby, 5, false), (.TXS, imp, 2, false), (.TAS, aby, 5, false),
            (.SHY, abx, 5, false), (.STA, abx, 5, false), (.SHX, aby, 5, false), (.AHX, aby, 5, false),
            // 0xA0
            (.LDY, imm, 2, false), (.LDA, izx, 6, false), (.LDX, imm, 2, false), (.LAX, izx, 6, false),
            (.LDY, zp,  3, false), (.LDA, zp,  3, false), (.LDX, zp,  3, false), (.LAX, zp,  3, false),
            (.TAY, imp, 2, false), (.LDA, imm, 2, false), (.TAX, imp, 2, false), (.LAX, imm, 2, false),
            (.LDY, abs, 4, false), (.LDA, abs, 4, false), (.LDX, abs, 4, false), (.LAX, abs, 4, false),
            // 0xB0
            (.BCS, rel, 2, true ), (.LDA, izy, 5, true ), (.KIL, imp, 2, false), (.LAX, izy, 5, true ),
            (.LDY, zpx, 4, false), (.LDA, zpx, 4, false), (.LDX, zpy, 4, false), (.LAX, zpy, 4, false),
            (.CLV, imp, 2, false), (.LDA, aby, 4, true ), (.TSX, imp, 2, false), (.LAS, aby, 4, true ),
            (.LDY, abx, 4, true ), (.LDA, abx, 4, true ), (.LDX, aby, 4, true ), (.LAX, aby, 4, true ),
            // 0xC0
            (.CPY, imm, 2, false), (.CMP, izx, 6, false), (.NOP, imm, 2, false), (.DCP, izx, 8, false),
            (.CPY, zp,  3, false), (.CMP, zp,  3, false), (.DEC, zp,  5, false), (.DCP, zp,  5, false),
            (.INY, imp, 2, false), (.CMP, imm, 2, false), (.DEX, imp, 2, false), (.AXS, imm, 2, false),
            (.CPY, abs, 4, false), (.CMP, abs, 4, false), (.DEC, abs, 6, false), (.DCP, abs, 6, false),
            // 0xD0
            (.BNE, rel, 2, true ), (.CMP, izy, 5, true ), (.KIL, imp, 2, false), (.DCP, izy, 8, false),
            (.NOP, zpx, 4, false), (.CMP, zpx, 4, false), (.DEC, zpx, 6, false), (.DCP, zpx, 6, false),
            (.CLD, imp, 2, false), (.CMP, aby, 4, true ), (.NOP, imp, 2, false), (.DCP, aby, 7, false),
            (.NOP, abx, 4, true ), (.CMP, abx, 4, true ), (.DEC, abx, 7, false), (.DCP, abx, 7, false),
            // 0xE0
            (.CPX, imm, 2, false), (.SBC, izx, 6, false), (.NOP, imm, 2, false), (.ISC, izx, 8, false),
            (.CPX, zp,  3, false), (.SBC, zp,  3, false), (.INC, zp,  5, false), (.ISC, zp,  5, false),
            (.INX, imp, 2, false), (.SBC, imm, 2, false), (.NOP, imp, 2, false), (.SBC, imm, 2, false),
            (.CPX, abs, 4, false), (.SBC, abs, 4, false), (.INC, abs, 6, false), (.ISC, abs, 6, false),
            // 0xF0
            (.BEQ, rel, 2, true ), (.SBC, izy, 5, true ), (.KIL, imp, 2, false), (.ISC, izy, 8, false),
            (.NOP, zpx, 4, false), (.SBC, zpx, 4, false), (.INC, zpx, 6, false), (.ISC, zpx, 6, false),
            (.SED, imp, 2, false), (.SBC, aby, 4, true ), (.NOP, imp, 2, false), (.ISC, aby, 7, false),
            (.NOP, abx, 4, true ), (.SBC, abx, 4, true ), (.INC, abx, 7, false), (.ISC, abx, 7, false),
        ]
        precondition(e.count == 256, "opcode table must have exactly 256 entries, has \(e.count)")
        return e.map { Instruction(mnemonic: $0.0, mode: $0.1, cycles: $0.2, pageCrossPenalty: $0.3) }
    }()

    @inline(__always)
    public static subscript(opcode: UInt8) -> Instruction { table[Int(opcode)] }
}
