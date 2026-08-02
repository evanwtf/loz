@testable import NESCore
import Testing

/// The shift and rotate helpers decompiled routines are built from.
///
/// These exist separately from the interpreter's own ROL/ROR tests for a
/// specific reason: the routine-equivalence suite that would otherwise catch a
/// mistake here needs `zelda.nes` and **skips on CI**. A helper that disagreed
/// with the interpreter would therefore pass every gate and only show up as a
/// decompiled routine that is subtly wrong.
///
/// So each case is asserted twice — once against the helper, once against the
/// interpreter executing the real opcode — and they must agree.
@Suite("CPU: shift and rotate helpers")
struct CPURotateHelperTests {
    /// Runs the real opcode on the accumulator and reports (result, carry).
    private func interpreted(opcode: UInt8, a: UInt8, carryIn: Bool) -> (UInt8, Bool) {
        let f = CPUFixture([carryIn ? 0x38 : 0x18, opcode])   // SEC/CLC, then the op
        f.cpu.a = a
        f.step(2)
        return (f.cpu.a, f.carry)
    }

    /// Runs the helper and reports the same pair.
    private func helper(
        _ apply: (CPU6502, UInt8) -> UInt8, a: UInt8, carryIn: Bool
    ) -> (UInt8, Bool) {
        let f = CPUFixture([0xEA])
        f.cpu.setCarry(carryIn)
        let result = apply(f.cpu, a)
        return (result, f.carry)
    }

    private func agree(opcode: UInt8, _ apply: (CPU6502, UInt8) -> UInt8, _ name: String) {
        for value in [UInt8(0x00), 0x01, 0x02, 0x7F, 0x80, 0x81, 0xAA, 0x55, 0xFF] {
            for carryIn in [false, true] {
                let expected = interpreted(opcode: opcode, a: value, carryIn: carryIn)
                let actual = helper(apply, a: value, carryIn: carryIn)
                #expect(
                    expected == actual,
                    "\(name) $\(String(value, radix: 16)) carry=\(carryIn)")
            }
        }
    }

    @Test("rotateLeft agrees with the interpreter's ROL for every input")
    func rotateLeftMatchesInterpreter() {
        agree(opcode: 0x2A, { $0.rotateLeft($1) }, "ROL")
    }

    @Test("rotateRight agrees with the interpreter's ROR for every input")
    func rotateRightMatchesInterpreter() {
        agree(opcode: 0x6A, { $0.rotateRight($1) }, "ROR")
    }

    @Test("shiftLeft agrees with the interpreter's ASL")
    func shiftLeftMatchesInterpreter() {
        agree(opcode: 0x0A, { $0.shiftLeft($1) }, "ASL")
    }

    @Test("shiftRight agrees with the interpreter's LSR")
    func shiftRightMatchesInterpreter() {
        agree(opcode: 0x4A, { $0.shiftRight($1) }, "LSR")
    }

    /// The distinction that makes rotates worth their own helpers: a rotate
    /// carries a bit *in*, a shift always brings in a zero. Using one for the
    /// other loses a bit per step, which is close enough to look plausible.
    @Test("A rotate brings the carry in where a shift brings in zero")
    func rotateIsNotAShift() {
        let f = CPUFixture([0xEA])

        f.cpu.setCarry(true)
        #expect(f.cpu.rotateLeft(0x00) == 0x01)
        f.cpu.setCarry(true)
        #expect(f.cpu.shiftLeft(0x00) == 0x00)

        f.cpu.setCarry(true)
        #expect(f.cpu.rotateRight(0x00) == 0x80)
        f.cpu.setCarry(true)
        #expect(f.cpu.shiftRight(0x00) == 0x00)
    }

    /// Three rotates left, with carry seeded from bit 0, is the idiom at
    /// `$9EDC` — it moves bits 0, 7 and 6 into the low three positions.
    @Test("The $9EDC rotate idiom lands bits 0, 7 and 6 in the low three")
    func rotateIdiom() {
        let f = CPUFixture([0xEA])
        for value in [UInt8(0x00), 0x01, 0x80, 0xC1, 0xFF, 0x5A] {
            _ = f.cpu.rotateRight(value)          // seed carry from bit 0
            var a = value
            for _ in 0..<3 { a = f.cpu.rotateLeft(a) }

            let b0 = (value >> 0) & 1
            let b7 = (value >> 7) & 1
            let b6 = (value >> 6) & 1
            #expect(a & 0x07 == (b0 << 2) | (b7 << 1) | b6, "value $\(String(value, radix: 16))")
        }
    }
}
