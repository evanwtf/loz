/// Everything the CPU can talk to. The bus owns the memory map.
public protocol CPUBus: AnyObject {
    func cpuRead(_ address: UInt16) -> UInt8
    func cpuWrite(_ address: UInt16, _ value: UInt8)
}

/// Ricoh 2A03 core — a 6502 with decimal mode disabled.
///
/// Beyond running the game, this is the reference implementation that
/// decompiled Swift routines are differentially tested against, so it aims for
/// exact register/flag semantics rather than raw speed.
public final class CPU6502 {

    // MARK: Registers

    public var a: UInt8 = 0
    public var x: UInt8 = 0
    public var y: UInt8 = 0
    public var sp: UInt8 = 0xFD
    public var pc: UInt16 = 0
    public var status: UInt8 = 0x24

    /// Total cycles elapsed since reset.
    public private(set) var totalCycles: Int = 0
    /// Cycles the CPU is held off the bus, e.g. during OAM DMA.
    public var stallCycles: Int = 0

    private var pendingNMI = false
    private var pendingIRQ = false

    public unowned var bus: CPUBus

    public init(bus: CPUBus) {
        self.bus = bus
    }

    // MARK: Status flags

    public struct Flag {
        public static let carry: UInt8     = 1 << 0
        public static let zero: UInt8      = 1 << 1
        public static let interrupt: UInt8 = 1 << 2
        public static let decimal: UInt8   = 1 << 3
        public static let breakCmd: UInt8  = 1 << 4
        public static let unused: UInt8    = 1 << 5
        public static let overflow: UInt8  = 1 << 6
        public static let negative: UInt8  = 1 << 7
    }

    @inline(__always)
    private func flag(_ f: UInt8) -> Bool { status & f != 0 }

    @inline(__always)
    private func setFlag(_ f: UInt8, _ on: Bool) {
        if on { status |= f } else { status &= ~f }
    }

    @inline(__always)
    private func setZN(_ value: UInt8) {
        setFlag(Flag.zero, value == 0)
        setFlag(Flag.negative, value & 0x80 != 0)
    }

    // MARK: Bus helpers

    @inline(__always) private func read(_ addr: UInt16) -> UInt8 { bus.cpuRead(addr) }
    @inline(__always) private func write(_ addr: UInt16, _ v: UInt8) { bus.cpuWrite(addr, v) }

    @inline(__always)
    private func read16(_ addr: UInt16) -> UInt16 {
        UInt16(read(addr)) | (UInt16(read(addr &+ 1)) << 8)
    }

    /// `JMP ($xxFF)` fetches the high byte from $xx00, not the next page.
    /// A genuine hardware bug that games occasionally depend on.
    @inline(__always)
    private func read16Bug(_ addr: UInt16) -> UInt16 {
        let lo = UInt16(read(addr))
        let hiAddr = (addr & 0xFF00) | UInt16((addr &+ 1) & 0x00FF)
        return lo | (UInt16(read(hiAddr)) << 8)
    }

    @inline(__always)
    private func push(_ value: UInt8) {
        write(0x0100 | UInt16(sp), value)
        sp &-= 1
    }

    @inline(__always)
    private func pull() -> UInt8 {
        sp &+= 1
        return read(0x0100 | UInt16(sp))
    }

    @inline(__always)
    private func push16(_ value: UInt16) {
        push(UInt8(value >> 8))
        push(UInt8(value & 0xFF))
    }

    @inline(__always)
    private func pull16() -> UInt16 {
        let lo = UInt16(pull())
        return lo | (UInt16(pull()) << 8)
    }

    // MARK: Interrupts

    public func reset() {
        a = 0; x = 0; y = 0
        sp = 0xFD
        status = 0x24
        pc = read16(0xFFFC)
        totalCycles = 0
        stallCycles = 0
        pendingNMI = false
        pendingIRQ = false
    }

    /// Performs an RTS without executing one.
    ///
    /// After a decompiled routine runs natively, control has to rejoin the
    /// interpreted caller exactly where the original `RTS` would have left it.
    public func returnFromSubroutine() {
        pc = pull16() &+ 1
    }

    /// Charges cycles for work done outside the interpreter, keeping the PPU in
    /// step with a natively-executed routine.
    public func advanceCycles(_ count: Int) {
        totalCycles += count
    }

    /// Latched by the PPU at the start of vblank.
    public func triggerNMI() { pendingNMI = true }
    /// Level-triggered; the APU/mapper assert and release it.
    public func setIRQLine(_ asserted: Bool) { pendingIRQ = asserted }

    private func serviceNMI() {
        push16(pc)
        // B clear, U set for a hardware interrupt.
        push((status & ~Flag.breakCmd) | Flag.unused)
        setFlag(Flag.interrupt, true)
        pc = read16(0xFFFA)
        totalCycles += 7
    }

    private func serviceIRQ() {
        push16(pc)
        push((status & ~Flag.breakCmd) | Flag.unused)
        setFlag(Flag.interrupt, true)
        pc = read16(0xFFFE)
        totalCycles += 7
    }

    // MARK: Execution

    /// Executes one instruction. Returns the cycles it consumed.
    @discardableResult
    public func step() -> Int {
        if stallCycles > 0 {
            stallCycles -= 1
            totalCycles += 1
            return 1
        }

        if pendingNMI {
            pendingNMI = false
            serviceNMI()
            return 7
        }
        if pendingIRQ && !flag(Flag.interrupt) {
            serviceIRQ()
            return 7
        }

        let startCycles = totalCycles
        let opcode = read(pc)
        let insn = Opcodes[opcode]
        pc &+= 1

        var cycles = insn.cycles
        let (address, pageCrossed) = resolve(insn.mode)
        if pageCrossed && insn.pageCrossPenalty { cycles += 1 }

        cycles += execute(insn, address: address)

        totalCycles = startCycles + cycles
        return cycles
    }

    // MARK: Addressing

    /// Resolves the operand address for a mode, advancing PC past the operand.
    /// Returns the effective address and whether indexing crossed a page.
    private func resolve(_ mode: AddressingMode) -> (address: UInt16, pageCrossed: Bool) {
        switch mode {
        case .implied, .accumulator:
            return (0, false)

        case .immediate:
            let addr = pc
            pc &+= 1
            return (addr, false)

        case .zeroPage:
            let addr = UInt16(read(pc))
            pc &+= 1
            return (addr, false)

        case .zeroPageX:
            let addr = UInt16(read(pc) &+ x)
            pc &+= 1
            return (addr, false)

        case .zeroPageY:
            let addr = UInt16(read(pc) &+ y)
            pc &+= 1
            return (addr, false)

        case .relative:
            let offset = read(pc)
            pc &+= 1
            // Sign-extend, resolved relative to the *next* instruction.
            let signed = Int8(bitPattern: offset)
            let target = UInt16(truncatingIfNeeded: Int(pc) + Int(signed))
            return (target, false)

        case .absolute:
            let addr = read16(pc)
            pc &+= 2
            return (addr, false)

        case .absoluteX:
            let base = read16(pc)
            pc &+= 2
            let addr = base &+ UInt16(x)
            return (addr, (base & 0xFF00) != (addr & 0xFF00))

        case .absoluteY:
            let base = read16(pc)
            pc &+= 2
            let addr = base &+ UInt16(y)
            return (addr, (base & 0xFF00) != (addr & 0xFF00))

        case .indirect:
            let ptr = read16(pc)
            pc &+= 2
            return (read16Bug(ptr), false)

        case .indexedIndirect:  // (zp,X)
            let zp = read(pc) &+ x
            pc &+= 1
            let lo = UInt16(read(UInt16(zp)))
            let hi = UInt16(read(UInt16(zp &+ 1)))
            return (lo | (hi << 8), false)

        case .indirectIndexed:  // (zp),Y
            let zp = read(pc)
            pc &+= 1
            let lo = UInt16(read(UInt16(zp)))
            let hi = UInt16(read(UInt16(zp &+ 1)))
            let base = lo | (hi << 8)
            let addr = base &+ UInt16(y)
            return (addr, (base & 0xFF00) != (addr & 0xFF00))
        }
    }

    // MARK: Instruction dispatch

    /// Returns any *extra* cycles beyond the table base (branch penalties).
    private func execute(_ insn: Instruction, address: UInt16) -> Int {
        let mode = insn.mode

        @inline(__always) func operand() -> UInt8 { read(address) }

        switch insn.mnemonic {

        // MARK: Load / store
        case .LDA: a = operand(); setZN(a)
        case .LDX: x = operand(); setZN(x)
        case .LDY: y = operand(); setZN(y)
        case .STA: write(address, a)
        case .STX: write(address, x)
        case .STY: write(address, y)

        // MARK: Transfers
        case .TAX: x = a; setZN(x)
        case .TAY: y = a; setZN(y)
        case .TXA: a = x; setZN(a)
        case .TYA: a = y; setZN(a)
        case .TSX: x = sp; setZN(x)
        case .TXS: sp = x                     // does not affect flags

        // MARK: Stack
        case .PHA: push(a)
        case .PHP: push(status | Flag.breakCmd | Flag.unused)
        case .PLA: a = pull(); setZN(a)
        case .PLP: status = (pull() & ~Flag.breakCmd) | Flag.unused

        // MARK: Logic
        case .AND: a &= operand(); setZN(a)
        case .ORA: a |= operand(); setZN(a)
        case .EOR: a ^= operand(); setZN(a)
        case .BIT:
            let v = operand()
            setFlag(Flag.zero, (a & v) == 0)
            setFlag(Flag.overflow, v & 0x40 != 0)
            setFlag(Flag.negative, v & 0x80 != 0)

        // MARK: Arithmetic
        case .ADC: adc(operand())
        case .SBC: adc(~operand())            // A - M - !C == A + ~M + C
        case .CMP: compare(a, operand())
        case .CPX: compare(x, operand())
        case .CPY: compare(y, operand())

        // MARK: Increment / decrement
        case .INC:
            let v = operand() &+ 1
            write(address, v); setZN(v)
        case .DEC:
            let v = operand() &- 1
            write(address, v); setZN(v)
        case .INX: x &+= 1; setZN(x)
        case .INY: y &+= 1; setZN(y)
        case .DEX: x &-= 1; setZN(x)
        case .DEY: y &-= 1; setZN(y)

        // MARK: Shifts
        case .ASL:
            if mode == .accumulator {
                setFlag(Flag.carry, a & 0x80 != 0); a <<= 1; setZN(a)
            } else {
                var v = operand()
                setFlag(Flag.carry, v & 0x80 != 0); v <<= 1
                write(address, v); setZN(v)
            }
        case .LSR:
            if mode == .accumulator {
                setFlag(Flag.carry, a & 0x01 != 0); a >>= 1; setZN(a)
            } else {
                var v = operand()
                setFlag(Flag.carry, v & 0x01 != 0); v >>= 1
                write(address, v); setZN(v)
            }
        case .ROL:
            let carryIn: UInt8 = flag(Flag.carry) ? 1 : 0
            if mode == .accumulator {
                setFlag(Flag.carry, a & 0x80 != 0); a = (a << 1) | carryIn; setZN(a)
            } else {
                var v = operand()
                setFlag(Flag.carry, v & 0x80 != 0); v = (v << 1) | carryIn
                write(address, v); setZN(v)
            }
        case .ROR:
            let carryIn: UInt8 = flag(Flag.carry) ? 0x80 : 0
            if mode == .accumulator {
                setFlag(Flag.carry, a & 0x01 != 0); a = (a >> 1) | carryIn; setZN(a)
            } else {
                var v = operand()
                setFlag(Flag.carry, v & 0x01 != 0); v = (v >> 1) | carryIn
                write(address, v); setZN(v)
            }

        // MARK: Jumps / calls
        case .JMP: pc = address
        case .JSR:
            push16(pc &- 1)                   // 6502 pushes the address of the last byte
            pc = address
        case .RTS: pc = pull16() &+ 1
        case .RTI:
            status = (pull() & ~Flag.breakCmd) | Flag.unused
            pc = pull16()
        case .BRK:
            pc &+= 1                          // BRK's operand byte is skipped
            push16(pc)
            push(status | Flag.breakCmd | Flag.unused)
            setFlag(Flag.interrupt, true)
            pc = read16(0xFFFE)

        // MARK: Branches
        case .BPL: return branch(address, if: !flag(Flag.negative))
        case .BMI: return branch(address, if:  flag(Flag.negative))
        case .BVC: return branch(address, if: !flag(Flag.overflow))
        case .BVS: return branch(address, if:  flag(Flag.overflow))
        case .BCC: return branch(address, if: !flag(Flag.carry))
        case .BCS: return branch(address, if:  flag(Flag.carry))
        case .BNE: return branch(address, if: !flag(Flag.zero))
        case .BEQ: return branch(address, if:  flag(Flag.zero))

        // MARK: Flag control
        case .CLC: setFlag(Flag.carry, false)
        case .SEC: setFlag(Flag.carry, true)
        case .CLI: setFlag(Flag.interrupt, false)
        case .SEI: setFlag(Flag.interrupt, true)
        case .CLV: setFlag(Flag.overflow, false)
        case .CLD: setFlag(Flag.decimal, false)
        case .SED: setFlag(Flag.decimal, true)

        case .NOP: break
        case .KIL: pc &-= 1                   // jams the CPU; keep it observable

        // MARK: Undocumented
        case .LAX: a = operand(); x = a; setZN(a)
        case .SAX: write(address, a & x)
        case .DCP:
            let v = operand() &- 1
            write(address, v); compare(a, v)
        case .ISC:
            let v = operand() &+ 1
            write(address, v); adc(~v)
        case .SLO:
            var v = operand()
            setFlag(Flag.carry, v & 0x80 != 0); v <<= 1
            write(address, v); a |= v; setZN(a)
        case .RLA:
            let carryIn: UInt8 = flag(Flag.carry) ? 1 : 0
            var v = operand()
            setFlag(Flag.carry, v & 0x80 != 0); v = (v << 1) | carryIn
            write(address, v); a &= v; setZN(a)
        case .SRE:
            var v = operand()
            setFlag(Flag.carry, v & 0x01 != 0); v >>= 1
            write(address, v); a ^= v; setZN(a)
        case .RRA:
            let carryIn: UInt8 = flag(Flag.carry) ? 0x80 : 0
            var v = operand()
            setFlag(Flag.carry, v & 0x01 != 0); v = (v >> 1) | carryIn
            write(address, v); adc(v)
        case .ANC:
            a &= operand(); setZN(a)
            setFlag(Flag.carry, a & 0x80 != 0)
        case .ALR:
            a &= operand()
            setFlag(Flag.carry, a & 0x01 != 0); a >>= 1; setZN(a)
        case .ARR:
            a &= operand()
            a = (a >> 1) | (flag(Flag.carry) ? 0x80 : 0)
            setZN(a)
            setFlag(Flag.carry, a & 0x40 != 0)
            setFlag(Flag.overflow, ((a >> 6) ^ (a >> 5)) & 1 != 0)
        case .AXS:
            let v = operand()
            let result = (a & x) &- v
            setFlag(Flag.carry, (a & x) >= v)
            x = result; setZN(x)
        case .LAS:
            let v = operand() & sp
            a = v; x = v; sp = v; setZN(v)
        // Unstable stores. Implemented as the common "high byte + 1" form; no
        // commercial game relies on these, they exist so the table is total.
        case .AHX: write(address, a & x & UInt8(truncatingIfNeeded: (address >> 8) &+ 1))
        case .SHX: write(address, x & UInt8(truncatingIfNeeded: (address >> 8) &+ 1))
        case .SHY: write(address, y & UInt8(truncatingIfNeeded: (address >> 8) &+ 1))
        case .TAS:
            sp = a & x
            write(address, sp & UInt8(truncatingIfNeeded: (address >> 8) &+ 1))
        case .XAA:
            a = x & operand(); setZN(a)
        }

        return 0
    }

    // MARK: Operation helpers

    /// Add with carry. The 2A03 has BCD disabled, so the D flag is ignored.
    @inline(__always)
    private func adc(_ value: UInt8) {
        let carryIn: UInt16 = flag(Flag.carry) ? 1 : 0
        let sum = UInt16(a) + UInt16(value) + carryIn
        let result = UInt8(truncatingIfNeeded: sum)
        setFlag(Flag.carry, sum > 0xFF)
        // Overflow when both operands share a sign that differs from the result.
        setFlag(Flag.overflow, ((a ^ result) & (value ^ result) & 0x80) != 0)
        a = result
        setZN(a)
    }

    @inline(__always)
    private func compare(_ register: UInt8, _ value: UInt8) {
        let diff = register &- value
        setFlag(Flag.carry, register >= value)
        setZN(diff)
    }

    /// +1 cycle if taken, +1 more if the target is on a different page.
    @inline(__always)
    private func branch(_ target: UInt16, if condition: Bool) -> Int {
        guard condition else { return 0 }
        let extra = (pc & 0xFF00) != (target & 0xFF00) ? 2 : 1
        pc = target
        return extra
    }
}
