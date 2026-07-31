@testable import NESCore
import Testing

/// Addressing-mode semantics, with emphasis on the wrapping and page-crossing
/// edge cases that quietly corrupt a decompilation if they are wrong.
@Suite("CPU: addressing modes")
struct CPUAddressingTests {
    @Test("Zero page")
    func zeroPage() {
        let f = CPUFixture([0xA5, 0x42])          // LDA $42
        f.bus[0x0042] = 0x37
        f.step()
        #expect(f.cpu.a == 0x37)
    }

    @Test("Zero page,X wraps within page zero")
    func zeroPageXWraps() {
        // LDA $FF,X with X=2 must read $0001, NOT $0101.
        let f = CPUFixture([0xB5, 0xFF])
        f.cpu.x = 0x02
        f.bus[0x0001] = 0xAB
        f.bus[0x0101] = 0xCD                      // decoy
        f.step()
        #expect(f.cpu.a == 0xAB)
    }

    @Test("Zero page,Y wraps within page zero")
    func zeroPageYWraps() {
        let f = CPUFixture([0xB6, 0xFF])          // LDX $FF,Y
        f.cpu.y = 0x03
        f.bus[0x0002] = 0x5A
        f.bus[0x0102] = 0xFF                      // decoy
        f.step()
        #expect(f.cpu.x == 0x5A)
    }

    @Test("Absolute")
    func absolute() {
        let f = CPUFixture([0xAD, 0x34, 0x12])    // LDA $1234
        f.bus[0x1234] = 0x99
        f.step()
        #expect(f.cpu.a == 0x99)
    }

    @Test("Absolute,X costs an extra cycle only when it crosses a page")
    func absoluteXPageCross() {
        // No cross: $12F0 + $05 = $12F5
        let noCross = CPUFixture([0xBD, 0xF0, 0x12])
        noCross.cpu.x = 0x05
        #expect(noCross.step() == 4)

        // Cross: $12F0 + $20 = $1310
        let cross = CPUFixture([0xBD, 0xF0, 0x12])
        cross.cpu.x = 0x20
        #expect(cross.step() == 5)
    }

    @Test("Absolute,Y costs an extra cycle only when it crosses a page")
    func absoluteYPageCross() {
        let noCross = CPUFixture([0xB9, 0x10, 0x20])
        noCross.cpu.y = 0x05
        #expect(noCross.step() == 4)

        let cross = CPUFixture([0xB9, 0xFF, 0x20])
        cross.cpu.y = 0x01
        #expect(cross.step() == 5)
    }

    @Test("Stores never take the page-cross penalty; it is in their base cost")
    func storesHaveFixedCost() {
        // STA $12F0,X always costs 5, crossing or not.
        let noCross = CPUFixture([0x9D, 0xF0, 0x12])
        noCross.cpu.x = 0x05
        #expect(noCross.step() == 5)

        let cross = CPUFixture([0x9D, 0xF0, 0x12])
        cross.cpu.x = 0x20
        #expect(cross.step() == 5)
    }

    @Test("Indexed indirect (zp,X) wraps the pointer in page zero")
    func indexedIndirectWraps() {
        // LDA ($FE,X) with X=2 -> pointer at $00/$01, not $0100.
        let f = CPUFixture([0xA1, 0xFE])
        f.cpu.x = 0x02
        f.bus[0x0000] = 0x00
        f.bus[0x0001] = 0x30                      // pointer -> $3000
        f.bus[0x3000] = 0x77
        f.step()
        #expect(f.cpu.a == 0x77)
    }

    @Test("Indexed indirect reads its high byte with zero-page wrap")
    func indexedIndirectHighByteWraps() {
        // Pointer at $FF: low from $FF, high from $00 (wrap), not $0100.
        let f = CPUFixture([0xA1, 0xFF])
        f.cpu.x = 0x00
        f.bus[0x00FF] = 0x11
        f.bus[0x0000] = 0x40                      // -> $4011
        f.bus[0x0100] = 0xEE                      // decoy
        f.bus[0x4011] = 0x63
        f.step()
        #expect(f.cpu.a == 0x63)
    }

    @Test("Indirect indexed (zp),Y adds Y after dereferencing")
    func indirectIndexed() {
        let f = CPUFixture([0xB1, 0x20])          // LDA ($20),Y
        f.cpu.y = 0x04
        f.bus[0x0020] = 0x00
        f.bus[0x0021] = 0x50                      // -> $5000
        f.bus[0x5004] = 0x42
        f.step()
        #expect(f.cpu.a == 0x42)
    }

    @Test("Indirect indexed costs an extra cycle on page cross")
    func indirectIndexedPageCross() {
        let noCross = CPUFixture([0xB1, 0x20])
        noCross.bus[0x0020] = 0x00
        noCross.bus[0x0021] = 0x50
        noCross.cpu.y = 0x04
        #expect(noCross.step() == 5)

        let cross = CPUFixture([0xB1, 0x20])
        cross.bus[0x0020] = 0xFF
        cross.bus[0x0021] = 0x50                  // $50FF + 1 = $5100
        cross.cpu.y = 0x01
        #expect(cross.step() == 6)
    }

    @Test("Indirect indexed wraps its pointer high byte in page zero")
    func indirectIndexedPointerWraps() {
        let f = CPUFixture([0xB1, 0xFF])
        f.bus[0x00FF] = 0x00
        f.bus[0x0000] = 0x60                      // -> $6000
        f.bus[0x0100] = 0xEE                      // decoy
        f.bus[0x6000] = 0x24
        f.cpu.y = 0
        f.step()
        #expect(f.cpu.a == 0x24)
    }

    @Test("JMP (indirect) reproduces the page-boundary hardware bug")
    func jmpIndirectPageBug() {
        // JMP ($30FF): low byte from $30FF, high byte wraps to $3000 — not $3100.
        let f = CPUFixture([0x6C, 0xFF, 0x30])
        f.bus[0x30FF] = 0x00
        f.bus[0x3100] = 0x40                      // what a naive impl would use
        f.bus[0x3000] = 0x80                      // what real hardware uses
        f.step()
        #expect(f.cpu.pc == 0x8000)
    }

    @Test("JMP (indirect) behaves normally away from a page boundary")
    func jmpIndirectNormal() {
        let f = CPUFixture([0x6C, 0x20, 0x30])
        f.bus[0x3020] = 0x34
        f.bus[0x3021] = 0x12
        f.step()
        #expect(f.cpu.pc == 0x1234)
    }
}
