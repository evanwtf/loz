import Testing
@testable import NESCore

/// A flat 64KB address space. Lets CPU tests exercise instruction semantics
/// without dragging in the PPU, mappers, or memory mirroring.
final class TestBus: CPUBus {
    var memory = [UInt8](repeating: 0, count: 0x10000)

    /// Every address touched, in order. Used to assert on dummy reads and on
    /// the exact write sequence of read-modify-write instructions.
    var readLog: [UInt16] = []
    var writeLog: [(address: UInt16, value: UInt8)] = []

    func cpuRead(_ address: UInt16) -> UInt8 {
        readLog.append(address)
        return memory[Int(address)]
    }

    func cpuWrite(_ address: UInt16, _ value: UInt8) {
        writeLog.append((address, value))
        memory[Int(address)] = value
    }

    subscript(address: UInt16) -> UInt8 {
        get { memory[Int(address)] }
        set { memory[Int(address)] = newValue }
    }

    func write16(_ address: UInt16, _ value: UInt16) {
        memory[Int(address)] = UInt8(value & 0xFF)
        memory[Int(address) + 1] = UInt8(value >> 8)
    }
}

/// A CPU wired to a flat bus with a program loaded and reset already applied.
final class CPUFixture {
    let bus = TestBus()
    let cpu: CPU6502
    let origin: UInt16

    /// - Parameters:
    ///   - program: bytes to place at `origin`.
    ///   - origin: load address; defaults into RAM so tests can write freely.
    init(_ program: [UInt8] = [], at origin: UInt16 = 0x0200) {
        self.origin = origin
        cpu = CPU6502(bus: bus)
        bus.write16(0xFFFC, origin)
        cpu.reset()
        for (i, byte) in program.enumerated() {
            bus.memory[Int(origin) + i] = byte
        }
        bus.readLog.removeAll()
        bus.writeLog.removeAll()
    }

    @discardableResult
    func step() -> Int { cpu.step() }

    /// Runs `count` instructions, returning total cycles.
    @discardableResult
    func step(_ count: Int) -> Int {
        (0..<count).reduce(0) { total, _ in total + cpu.step() }
    }

    // Flag accessors, so assertions read like the datasheet.
    var carry: Bool     { cpu.status & CPU6502.Flag.carry != 0 }
    var zero: Bool      { cpu.status & CPU6502.Flag.zero != 0 }
    var interrupt: Bool { cpu.status & CPU6502.Flag.interrupt != 0 }
    var decimal: Bool   { cpu.status & CPU6502.Flag.decimal != 0 }
    var overflow: Bool  { cpu.status & CPU6502.Flag.overflow != 0 }
    var negative: Bool  { cpu.status & CPU6502.Flag.negative != 0 }

    /// Raw byte `depth` slots above the current SP (the most recent push is 1).
    func stack(_ depth: Int = 1) -> UInt8 {
        bus[0x0100 | UInt16(cpu.sp &+ UInt8(depth))]
    }

    // The stack grows downward and `push16` writes the high byte first, so a
    // frame reads back as [SP+1] = last pushed. Encoding that once here keeps
    // byte-order mistakes out of the individual tests.

    /// Return address pushed by JSR — i.e. the address of the JSR's last byte.
    var pushedReturnAddress: UInt16 {
        UInt16(stack(1)) | (UInt16(stack(2)) << 8)
    }

    /// Status byte pushed by an interrupt or BRK.
    var pushedStatus: UInt8 { stack(1) }

    /// Program counter pushed by an interrupt or BRK, beneath the status byte.
    var pushedPC: UInt16 {
        UInt16(stack(2)) | (UInt16(stack(3)) << 8)
    }
}
