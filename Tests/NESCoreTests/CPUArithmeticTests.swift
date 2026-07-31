import Testing
@testable import NESCore

/// ADC/SBC/compare semantics. The overflow flag is the classic source of subtle
/// emulator bugs, so all four sign combinations are covered explicitly.
@Suite("CPU: arithmetic and flags")
struct CPUArithmeticTests {

    // MARK: ADC

    @Test("ADC adds with carry in")
    func adcBasic() {
        let f = CPUFixture([0x69, 0x10])          // ADC #$10
        f.cpu.a = 0x20
        f.step()
        #expect(f.cpu.a == 0x30)
        #expect(!f.carry)
        #expect(!f.overflow)
    }

    @Test("ADC includes the carry flag as input")
    func adcUsesCarryIn() {
        let f = CPUFixture([0x38, 0x69, 0x10])    // SEC; ADC #$10
        f.cpu.a = 0x20
        f.step(2)
        #expect(f.cpu.a == 0x31)
    }

    @Test("ADC sets carry on unsigned overflow")
    func adcCarryOut() {
        let f = CPUFixture([0x69, 0x01])
        f.cpu.a = 0xFF
        f.step()
        #expect(f.cpu.a == 0x00)
        #expect(f.carry)
        #expect(f.zero)
    }

    // The V flag is set only when two like-signed operands produce a
    // differently-signed result.
    @Test("ADC overflow: positive + positive = negative sets V",
          arguments: [(UInt8(0x50), UInt8(0x50), UInt8(0xA0), true)])
    func adcOverflowPosPos(a: UInt8, operand: UInt8, result: UInt8, v: Bool) {
        let f = CPUFixture([0x69, operand])
        f.cpu.a = a
        f.step()
        #expect(f.cpu.a == result)
        #expect(f.overflow == v)
    }

    @Test("ADC overflow: negative + negative = positive sets V")
    func adcOverflowNegNeg() {
        let f = CPUFixture([0x69, 0x90])          // -112 + -112
        f.cpu.a = 0x90
        f.step()
        #expect(f.cpu.a == 0x20)
        #expect(f.overflow)
        #expect(f.carry)
    }

    @Test("ADC overflow: mixed signs never set V")
    func adcNoOverflowMixedSigns() {
        let f = CPUFixture([0x69, 0xD0])          // 80 + -48
        f.cpu.a = 0x50
        f.step()
        #expect(f.cpu.a == 0x20)
        #expect(!f.overflow)
        #expect(f.carry)
    }

    @Test("ADC ignores the decimal flag — the 2A03 has BCD disabled")
    func adcIgnoresDecimalMode() {
        let f = CPUFixture([0xF8, 0x69, 0x01])    // SED; ADC #$01
        f.cpu.a = 0x09
        f.step(2)
        #expect(f.decimal)                        // flag is settable...
        #expect(f.cpu.a == 0x0A)                  // ...but arithmetic stays binary
    }

    // MARK: SBC

    @Test("SBC subtracts with borrow (carry set means no borrow)")
    func sbcBasic() {
        let f = CPUFixture([0x38, 0xE9, 0x10])    // SEC; SBC #$10
        f.cpu.a = 0x50
        f.step(2)
        #expect(f.cpu.a == 0x40)
        #expect(f.carry)                          // no borrow occurred
    }

    @Test("SBC with carry clear subtracts an extra one")
    func sbcWithBorrow() {
        let f = CPUFixture([0x18, 0xE9, 0x10])    // CLC; SBC #$10
        f.cpu.a = 0x50
        f.step(2)
        #expect(f.cpu.a == 0x3F)
    }

    @Test("SBC clears carry when the result borrows")
    func sbcBorrowOut() {
        let f = CPUFixture([0x38, 0xE9, 0x10])
        f.cpu.a = 0x05
        f.step(2)
        #expect(f.cpu.a == 0xF5)
        #expect(!f.carry)
        #expect(f.negative)
    }

    @Test("SBC sets overflow on signed underflow")
    func sbcOverflow() {
        // 80 - (-80) = 160, which overflows a signed byte.
        let f = CPUFixture([0x38, 0xE9, 0xB0])
        f.cpu.a = 0x50
        f.step(2)
        #expect(f.overflow)
    }

    // MARK: Compares

    @Test("CMP sets carry when A >= operand")
    func cmpGreaterOrEqual() {
        let f = CPUFixture([0xC9, 0x30])
        f.cpu.a = 0x50
        f.step()
        #expect(f.carry)
        #expect(!f.zero)
        #expect(!f.negative)
    }

    @Test("CMP sets zero and carry on equality")
    func cmpEqual() {
        let f = CPUFixture([0xC9, 0x50])
        f.cpu.a = 0x50
        f.step()
        #expect(f.carry)
        #expect(f.zero)
    }

    @Test("CMP clears carry when A < operand")
    func cmpLess() {
        let f = CPUFixture([0xC9, 0x60])
        f.cpu.a = 0x50
        f.step()
        #expect(!f.carry)
        #expect(!f.zero)
    }

    @Test("CMP does not modify the accumulator")
    func cmpPreservesA() {
        let f = CPUFixture([0xC9, 0x30])
        f.cpu.a = 0x50
        f.step()
        #expect(f.cpu.a == 0x50)
    }

    @Test("CPX and CPY compare their own registers")
    func compareIndexRegisters() {
        let fx = CPUFixture([0xE0, 0x10])         // CPX #$10
        fx.cpu.x = 0x10
        fx.step()
        #expect(fx.zero)

        let fy = CPUFixture([0xC0, 0x10])         // CPY #$10
        fy.cpu.y = 0x20
        fy.step()
        #expect(fy.carry)
        #expect(!fy.zero)
    }

    // MARK: BIT

    @Test("BIT copies bits 7 and 6 of the operand into N and V")
    func bitFlags() {
        let f = CPUFixture([0x24, 0x10])          // BIT $10
        f.bus[0x0010] = 0xC0                      // bits 7 and 6 set
        f.cpu.a = 0x00
        f.step()
        #expect(f.negative)
        #expect(f.overflow)
        #expect(f.zero)                           // A & M == 0
    }

    @Test("BIT sets zero from A AND M without altering A")
    func bitAndResult() {
        let f = CPUFixture([0x24, 0x10])
        f.bus[0x0010] = 0x0F
        f.cpu.a = 0x01
        f.step()
        #expect(!f.zero)
        #expect(f.cpu.a == 0x01)
    }

    // MARK: Shifts and rotates

    @Test("ASL shifts left and captures bit 7 in carry")
    func aslAccumulator() {
        let f = CPUFixture([0x0A])                // ASL A
        f.cpu.a = 0x81
        f.step()
        #expect(f.cpu.a == 0x02)
        #expect(f.carry)
    }

    @Test("LSR shifts right and captures bit 0 in carry")
    func lsrAccumulator() {
        let f = CPUFixture([0x4A])
        f.cpu.a = 0x03
        f.step()
        #expect(f.cpu.a == 0x01)
        #expect(f.carry)
        #expect(!f.negative)                      // LSR always clears N
    }

    @Test("ROL rotates carry in at bit 0")
    func rolThroughCarry() {
        let f = CPUFixture([0x38, 0x2A])          // SEC; ROL A
        f.cpu.a = 0x80
        f.step(2)
        #expect(f.cpu.a == 0x01)
        #expect(f.carry)
    }

    @Test("ROR rotates carry in at bit 7")
    func rorThroughCarry() {
        let f = CPUFixture([0x38, 0x6A])          // SEC; ROR A
        f.cpu.a = 0x01
        f.step(2)
        #expect(f.cpu.a == 0x80)
        #expect(f.carry)
        #expect(f.negative)
    }

    @Test("Memory shifts write the result back")
    func aslMemory() {
        let f = CPUFixture([0x06, 0x10])          // ASL $10
        f.bus[0x0010] = 0x40
        f.step()
        #expect(f.bus[0x0010] == 0x80)
        #expect(!f.carry)
        #expect(f.negative)
    }

    // MARK: Increment / decrement

    @Test("INC and DEC wrap and set flags")
    func incDecWrap() {
        let inc = CPUFixture([0xE6, 0x10])        // INC $10
        inc.bus[0x0010] = 0xFF
        inc.step()
        #expect(inc.bus[0x0010] == 0x00)
        #expect(inc.zero)

        let dec = CPUFixture([0xC6, 0x10])        // DEC $10
        dec.bus[0x0010] = 0x00
        dec.step()
        #expect(dec.bus[0x0010] == 0xFF)
        #expect(dec.negative)
    }

    @Test("INX/INY/DEX/DEY wrap around")
    func indexRegisterWrap() {
        let f = CPUFixture([0xE8, 0xC8, 0xCA, 0x88])
        f.cpu.x = 0xFF
        f.cpu.y = 0xFF
        f.step()
        #expect(f.cpu.x == 0x00)
        f.step()
        #expect(f.cpu.y == 0x00)
        f.step()
        #expect(f.cpu.x == 0xFF)
        f.step()
        #expect(f.cpu.y == 0xFF)
    }
}
