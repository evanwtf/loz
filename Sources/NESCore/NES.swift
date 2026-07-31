/// A whole console: CPU, PPU, cartridge, and controllers, wired together.
///
/// `NES` doubles as the CPU's bus — it owns the address decoding for the
/// entire $0000-$FFFF space.
public final class NES {

    public let cartridge: Cartridge
    public let mapper: Mapper
    public let ppu: PPU
    public let controller1 = Controller()
    public let controller2 = Controller()

    /// 2KB of internal work RAM, mirrored through $1FFF.
    public internal(set) var ram = [UInt8](repeating: 0, count: 0x800)

    public private(set) var cpu: CPU6502!

    /// Total CPU cycles since power-on.
    public private(set) var cycles = 0

    /// Routines that have been decompiled to Swift. When the CPU reaches a
    /// registered address the native version runs instead of the interpreter.
    /// Empty by default, so an unmodified `NES` is a plain emulator.
    public var nativeRoutines = RoutineTable()

    /// Counts how often each native routine ran — useful for confirming a
    /// conversion is actually on the hot path before optimising it.
    public private(set) var nativeCallCounts: [RoutineKey: Int] = [:]

    public init(cartridge: Cartridge) throws {
        self.cartridge = cartridge
        self.mapper = try cartridge.makeMapper()
        self.ppu = PPU(mapper: mapper)
        self.cpu = CPU6502(bus: self)
        cpu.reset()
    }

    public convenience init(romData: [UInt8]) throws {
        try self.init(cartridge: try Cartridge(data: romData))
    }

    public func reset() {
        ppu.reset()
        cpu.reset()
        cycles = 0
    }

    // MARK: Clocking

    /// Runs one CPU instruction and the three-times-faster PPU alongside it.
    @discardableResult
    public func step() -> Int {
        let cpuCycles = dispatchNativeRoutine() ?? cpu.step()

        for _ in 0..<(cpuCycles * 3) {
            ppu.step()
            if ppu.nmiRequested {
                ppu.nmiRequested = false
                cpu.triggerNMI()
            }
        }
        // Mappers with a scanline counter raise IRQ from PPU activity.
        cpu.setIRQLine(mapper.irqAsserted)

        cycles += cpuCycles
        return cpuCycles
    }

    /// If a decompiled routine is registered at the current PC, runs it and
    /// returns to the caller. Returns the cycles consumed, or nil when the
    /// interpreter should handle this instruction.
    private func dispatchNativeRoutine() -> Int? {
        guard !nativeRoutines.isEmpty, cpu.stallCycles == 0 else { return nil }

        let key = RoutineKey(bank: mapper.currentPRGBank, address: cpu.pc)
        guard let routine = nativeRoutines[key] else { return nil }

        routine.body(self)
        cpu.returnFromSubroutine()
        cpu.advanceCycles(routine.cycles)
        nativeCallCounts[key, default: 0] += 1
        return routine.cycles
    }

    /// Runs until the PPU signals the end of a frame.
    public func stepFrame() {
        ppu.frameComplete = false
        var guardCounter = 0
        // A frame is ~29,780 CPU cycles; the cap only catches a wedged CPU.
        while !ppu.frameComplete && guardCounter < 100_000 {
            step()
            guardCounter += 1
        }
    }

    /// The current video output, 256x240 RGBA.
    public var framebuffer: [UInt32] { ppu.framebuffer }
}

// MARK: - CPU address decoding

extension NES: CPUBus {

    public func cpuRead(_ address: UInt16) -> UInt8 {
        switch address {
        case 0x0000...0x1FFF:
            // 2KB mirrored four times.
            return ram[Int(address & 0x07FF)]

        case 0x2000...0x3FFF:
            // Eight registers mirrored every 8 bytes.
            return ppu.readRegister(address & 0x2007)

        case 0x4016:
            return controller1.read()

        case 0x4017:
            return controller2.read()

        case 0x4000...0x4015:
            // APU. Reads other than $4015 are open bus.
            return 0

        default:
            return mapper.cpuRead(address) ?? 0
        }
    }

    public func cpuWrite(_ address: UInt16, _ value: UInt8) {
        switch address {
        case 0x0000...0x1FFF:
            ram[Int(address & 0x07FF)] = value

        case 0x2000...0x3FFF:
            ppu.writeRegister(address & 0x2007, value)

        case 0x4014:
            performOAMDMA(page: value)

        case 0x4016:
            // A write to $4016 strobes both ports.
            controller1.write(value)
            controller2.write(value)

        case 0x4000...0x4017:
            break   // APU, not yet implemented

        default:
            mapper.cpuWrite(address, value)
        }
    }

    /// $4014: copies 256 bytes from CPU page `page` into OAM.
    ///
    /// The real transfer is interleaved with CPU cycles; copying in one go and
    /// charging the stall up front is equivalent for everything short of a
    /// game that reprograms the PPU mid-DMA.
    private func performOAMDMA(page: UInt8) {
        let base = UInt16(page) << 8
        for i in 0..<256 {
            ppu.writeOAM(i, cpuRead(base &+ UInt16(i)))
        }
        // 512 cycles of copying plus one idle; one more on an odd CPU cycle.
        cpu.stallCycles += 513 + (cycles % 2)
    }
}
