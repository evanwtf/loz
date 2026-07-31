@testable import NESCore
import Testing

/// Branches, subroutines, the stack, and interrupt dispatch — the machinery the
/// decompiler has to reason about when recovering control flow.
@Suite("CPU: control flow, stack, interrupts")
struct CPUControlFlowTests {
    // MARK: Branches

    @Test("A not-taken branch costs 2 cycles and falls through")
    func branchNotTaken() {
        let f = CPUFixture([0xD0, 0x10])          // BNE +$10
        f.cpu.status |= CPU6502.Flag.zero         // Z set -> not taken
        let cycles = f.step()
        #expect(cycles == 2)
        #expect(f.cpu.pc == f.origin + 2)
    }

    @Test("A taken branch costs 3 cycles within the same page")
    func branchTakenSamePage() {
        let f = CPUFixture([0xD0, 0x10])
        f.cpu.status &= ~CPU6502.Flag.zero
        let cycles = f.step()
        #expect(cycles == 3)
        #expect(f.cpu.pc == f.origin + 2 + 0x10)
    }

    @Test("A taken branch costs 4 cycles when it crosses a page")
    func branchTakenPageCross() {
        // Place the branch so the target lands on the next page.
        let f = CPUFixture([0xD0, 0x7F], at: 0x02F0)
        f.cpu.status &= ~CPU6502.Flag.zero
        let cycles = f.step()
        #expect(cycles == 4)
        #expect(f.cpu.pc == 0x0371)
    }

    @Test("Branch offsets are signed")
    func branchBackwards() {
        let f = CPUFixture([0xD0, 0xFC], at: 0x0210)   // BNE -4
        f.cpu.status &= ~CPU6502.Flag.zero
        f.step()
        #expect(f.cpu.pc == 0x020E)
    }

    @Test("Every branch tests the right flag in the right direction")
    func allBranchConditions() {
        // (opcode, flag, branchesWhenFlagSet)
        let cases: [(UInt8, UInt8, Bool)] = [
            (0x10, CPU6502.Flag.negative, false),  // BPL
            (0x30, CPU6502.Flag.negative, true),   // BMI
            (0x50, CPU6502.Flag.overflow, false),  // BVC
            (0x70, CPU6502.Flag.overflow, true),   // BVS
            (0x90, CPU6502.Flag.carry,    false),  // BCC
            (0xB0, CPU6502.Flag.carry,    true),   // BCS
            (0xD0, CPU6502.Flag.zero,     false),  // BNE
            (0xF0, CPU6502.Flag.zero,     true),   // BEQ
        ]
        for (opcode, flag, takenWhenSet) in cases {
            for flagSet in [true, false] {
                let f = CPUFixture([opcode, 0x10])
                if flagSet { f.cpu.status |= flag } else { f.cpu.status &= ~flag }
                f.step()
                let taken = f.cpu.pc != f.origin + 2
                #expect(taken == (flagSet == takenWhenSet),
                        "opcode \(String(format: "%02X", opcode)) flagSet=\(flagSet)")
            }
        }
    }

    // MARK: JSR / RTS

    @Test("JSR pushes the address of its own last byte")
    func jsrPushesReturnMinusOne() {
        let f = CPUFixture([0x20, 0x00, 0x40], at: 0x0200)   // JSR $4000
        f.step()
        #expect(f.cpu.pc == 0x4000)
        // Return address pushed is $0202 — the last byte of the JSR, not $0203.
        #expect(f.pushedReturnAddress == 0x0202)
        #expect(f.cpu.sp == 0xFB)                 // two bytes consumed
    }

    @Test("RTS returns to the pushed address plus one")
    func rtsRoundTrip() {
        let f = CPUFixture([0x20, 0x00, 0x40], at: 0x0200)
        f.bus[0x4000] = 0x60                      // RTS
        f.step()                                  // JSR
        f.step()                                  // RTS
        #expect(f.cpu.pc == 0x0203)               // instruction after the JSR
        #expect(f.cpu.sp == 0xFD)                 // stack restored
    }

    @Test("Nested subroutines unwind correctly")
    func nestedCalls() {
        let f = CPUFixture([0x20, 0x00, 0x40], at: 0x0200)
        f.bus[0x4000] = 0x20                      // JSR $5000
        f.bus[0x4001] = 0x00
        f.bus[0x4002] = 0x50
        f.bus[0x4003] = 0x60                      // RTS
        f.bus[0x5000] = 0x60                      // RTS
        f.step()                                  // JSR $4000
        f.step()                                  // JSR $5000
        #expect(f.cpu.sp == 0xF9)
        f.step()                                  // RTS -> $4003
        #expect(f.cpu.pc == 0x4003)
        f.step()                                  // RTS -> $0203
        #expect(f.cpu.pc == 0x0203)
        #expect(f.cpu.sp == 0xFD)
    }

    @Test("JSR takes 6 cycles, RTS takes 6")
    func subroutineCycles() {
        let f = CPUFixture([0x20, 0x00, 0x40])
        f.bus[0x4000] = 0x60
        #expect(f.step() == 6)
        #expect(f.step() == 6)
    }

    // MARK: Stack

    @Test("PHA/PLA round-trips through the stack")
    func pushPullAccumulator() {
        let f = CPUFixture([0x48, 0xA9, 0x00, 0x68])   // PHA; LDA #$00; PLA
        f.cpu.a = 0x42
        f.step(2)                                 // PHA, then clobber A
        #expect(f.cpu.a == 0x00)
        f.step()                                  // PLA restores it
        #expect(f.cpu.a == 0x42)
    }

    @Test("PHP pushes with B and unused set")
    func phpSetsBreakAndUnused() {
        let f = CPUFixture([0x08])                // PHP
        f.cpu.status = 0x00
        f.step()
        #expect(f.stack(1) == (CPU6502.Flag.breakCmd | CPU6502.Flag.unused))
    }

    @Test("PLP clears B and forces unused set")
    func plpMasksBreak() {
        let f = CPUFixture([0x28])                // PLP
        f.cpu.sp = 0xFC
        f.bus[0x01FD] = 0xFF                      // all bits set
        f.step()
        #expect(f.cpu.status & CPU6502.Flag.breakCmd == 0)
        #expect(f.cpu.status & CPU6502.Flag.unused != 0)
    }

    @Test("The stack pointer wraps within page one")
    func stackWraps() {
        let f = CPUFixture([0x48, 0x48])
        f.cpu.sp = 0x00
        f.step()
        #expect(f.cpu.sp == 0xFF)                 // wrapped
        f.step()
        #expect(f.cpu.sp == 0xFE)
    }

    // MARK: Interrupts

    @Test("NMI pushes PC and status, then vectors through $FFFA")
    func nmiDispatch() {
        let f = CPUFixture([0xEA], at: 0x0200)    // NOP
        f.bus.write16(0xFFFA, 0x9000)
        f.cpu.triggerNMI()
        let cycles = f.step()
        #expect(cycles == 7)
        #expect(f.cpu.pc == 0x9000)
        #expect(f.interrupt)                      // I set on entry
        // PC pushed is the un-executed instruction address.
        #expect(f.pushedPC == 0x0200)
    }

    @Test("A hardware interrupt pushes status with B clear")
    func nmiPushesBreakClear() {
        let f = CPUFixture([0xEA])
        f.bus.write16(0xFFFA, 0x9000)
        f.cpu.status = 0x00
        f.cpu.triggerNMI()
        f.step()
        #expect(f.pushedStatus & CPU6502.Flag.breakCmd == 0)
        #expect(f.pushedStatus & CPU6502.Flag.unused != 0)
    }

    @Test("NMI fires once per trigger")
    func nmiIsEdgeTriggered() {
        let f = CPUFixture([0xEA, 0xEA], at: 0x0200)
        f.bus.write16(0xFFFA, 0x9000)
        f.bus[0x9000] = 0xEA
        f.cpu.triggerNMI()
        f.step()
        #expect(f.cpu.pc == 0x9000)
        f.step()                                  // should just run the NOP
        #expect(f.cpu.pc == 0x9001)
    }

    @Test("IRQ is masked while the interrupt-disable flag is set")
    func irqRespectsMask() {
        let f = CPUFixture([0xEA], at: 0x0200)
        f.bus.write16(0xFFFE, 0xA000)
        f.cpu.status |= CPU6502.Flag.interrupt    // masked
        f.cpu.setIRQLine(true)
        f.step()
        #expect(f.cpu.pc == 0x0201)               // NOP ran; IRQ ignored
    }

    @Test("IRQ dispatches once the mask is cleared")
    func irqFiresWhenUnmasked() {
        let f = CPUFixture([0x58, 0xEA], at: 0x0200)   // CLI; NOP
        f.bus.write16(0xFFFE, 0xA000)
        f.cpu.setIRQLine(true)
        f.step()                                  // CLI
        f.step()                                  // IRQ taken instead of NOP
        #expect(f.cpu.pc == 0xA000)
    }

    @Test("BRK pushes status with B set and skips its signature byte")
    func brkSemantics() {
        let f = CPUFixture([0x00, 0xFF], at: 0x0200)   // BRK, then padding
        f.bus.write16(0xFFFE, 0xB000)
        f.step()
        #expect(f.cpu.pc == 0xB000)
        #expect(f.pushedStatus & CPU6502.Flag.breakCmd != 0)
        // BRK pushes PC+2, skipping the byte after the opcode.
        #expect(f.pushedPC == 0x0202)
    }

    @Test("RTI restores status and PC exactly")
    func rtiRestores() {
        let f = CPUFixture([0x40], at: 0x0200)    // RTI
        f.cpu.sp = 0xFA
        f.bus[0x01FB] = 0xC5                      // status
        f.bus[0x01FC] = 0x34                      // PC low
        f.bus[0x01FD] = 0x12                      // PC high
        f.step()
        #expect(f.cpu.pc == 0x1234)
        #expect(f.cpu.status & CPU6502.Flag.breakCmd == 0)
        #expect(f.cpu.status & CPU6502.Flag.unused != 0)
        #expect(f.cpu.status & CPU6502.Flag.carry != 0)   // bit 0 of $C5
    }

    @Test("Reset initialises SP and vectors through $FFFC")
    func resetState() {
        let bus = TestBus()
        bus.write16(0xFFFC, 0xC5F0)
        let cpu = CPU6502(bus: bus)
        cpu.reset()
        #expect(cpu.pc == 0xC5F0)
        #expect(cpu.sp == 0xFD)
        #expect(cpu.status & CPU6502.Flag.interrupt != 0)
    }

    // MARK: Transfers

    @Test("TXS is the only transfer that leaves flags alone")
    func txsDoesNotSetFlags() {
        let f = CPUFixture([0x9A])                // TXS
        f.cpu.x = 0x00
        f.cpu.status &= ~CPU6502.Flag.zero
        f.step()
        #expect(f.cpu.sp == 0x00)
        #expect(!f.zero)                          // would be set by any other transfer

        let tsx = CPUFixture([0xBA])              // TSX does set them
        tsx.cpu.sp = 0x00
        tsx.step()
        #expect(tsx.zero)
    }
}
