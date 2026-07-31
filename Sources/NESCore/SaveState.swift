import Foundation

/// A complete snapshot of the machine.
///
/// The point of this is exploration cost. Reaching Zelda's overworld means
/// booting, sitting through the title, registering a name, and selecting a
/// file — hundreds of frames of menu navigation before any actual game code
/// runs. With snapshots that happens once, and every later investigation
/// branches from a saved point.
public struct SaveState: Codable, Sendable {
    public struct CPUState: Codable, Sendable {
        public var a: UInt8
        public var x: UInt8
        public var y: UInt8
        public var sp: UInt8
        public var pc: UInt16
        public var status: UInt8
        public var totalCycles: Int
        public var stallCycles: Int
    }

    public struct PPUState: Codable, Sendable {
        public var control: UInt8
        public var mask: UInt8
        public var status: UInt8
        public var oamAddress: UInt8
        public var v: UInt16
        public var t: UInt16
        public var fineX: UInt8
        public var writeToggle: Bool
        public var readBuffer: UInt8
        public var scanline: Int
        public var dot: Int
        public var frame: Int
        public var vram: [UInt8]
        public var paletteRAM: [UInt8]
        public var oam: [UInt8]
    }

    /// Format version, so an old snapshot fails loudly instead of loading
    /// garbage into a changed layout.
    public var version = 1
    public var romHash: String
    public var cpu: CPUState
    public var ppu: PPUState
    public var ram: [UInt8]
    public var prgRAM: [UInt8]
    /// CHR-RAM contents; on a board like Zelda's this holds all the loaded tiles.
    public var chr: [UInt8]
    public var mapperState: [UInt8]
    public var cycles: Int
}

public enum SaveStateError: Error, CustomStringConvertible {
    case versionMismatch(found: Int, expected: Int)
    case romMismatch
    case sizeMismatch(field: String)

    public var description: String {
        switch self {
        case let .versionMismatch(found, expected):
            "Save state version \(found) is not supported (expected \(expected))."
        case .romMismatch:
            "Save state was made with a different ROM."
        case let .sizeMismatch(field):
            "Save state field '\(field)' has the wrong size."
        }
    }
}

public extension NES {
    /// Captures the full machine state.
    func captureState(romHash: String = "") -> SaveState {
        SaveState(
            romHash: romHash,
            cpu: SaveState.CPUState(
                a: cpu.a, x: cpu.x, y: cpu.y, sp: cpu.sp, pc: cpu.pc,
                status: cpu.status, totalCycles: cpu.totalCycles,
                stallCycles: cpu.stallCycles),
            ppu: SaveState.PPUState(
                control: ppu.control.rawValue,
                mask: ppu.mask.rawValue,
                status: ppu.status.rawValue,
                oamAddress: ppu.oamAddress,
                v: ppu.v, t: ppu.t, fineX: ppu.fineX,
                writeToggle: ppu.writeToggle,
                readBuffer: ppu.readBufferValue,
                scanline: ppu.scanline, dot: ppu.dot, frame: ppu.frame,
                vram: ppu.vram, paletteRAM: ppu.paletteRAM, oam: ppu.oam),
            ram: ram,
            prgRAM: cartridge.prgRAM,
            chr: cartridge.chr,
            mapperState: mapper.persistentState,
            cycles: cycles)
    }

    /// Restores a previously captured state.
    func restoreState(_ state: SaveState, romHash: String = "") throws {
        guard state.version == 1 else {
            throw SaveStateError.versionMismatch(found: state.version, expected: 1)
        }
        if !romHash.isEmpty, !state.romHash.isEmpty, state.romHash != romHash {
            throw SaveStateError.romMismatch
        }
        guard state.ram.count == ram.count else {
            throw SaveStateError.sizeMismatch(field: "ram")
        }
        guard state.chr.count == cartridge.chr.count else {
            throw SaveStateError.sizeMismatch(field: "chr")
        }

        cpu.a = state.cpu.a
        cpu.x = state.cpu.x
        cpu.y = state.cpu.y
        cpu.sp = state.cpu.sp
        cpu.pc = state.cpu.pc
        cpu.status = state.cpu.status
        cpu.restoreCycles(total: state.cpu.totalCycles, stall: state.cpu.stallCycles)

        ppu.control = PPU.Control(rawValue: state.ppu.control)
        ppu.mask = PPU.Mask(rawValue: state.ppu.mask)
        ppu.status = PPU.Status(rawValue: state.ppu.status)
        ppu.oamAddress = state.ppu.oamAddress
        ppu.v = state.ppu.v
        ppu.t = state.ppu.t
        ppu.fineX = state.ppu.fineX
        ppu.writeToggle = state.ppu.writeToggle
        ppu.restore(
            readBuffer: state.ppu.readBuffer,
            scanline: state.ppu.scanline,
            dot: state.ppu.dot,
            frame: state.ppu.frame)
        ppu.vram = state.ppu.vram
        ppu.paletteRAM = state.ppu.paletteRAM
        ppu.oam = state.ppu.oam

        ram = state.ram
        cartridge.prgRAM = state.prgRAM
        cartridge.chr = state.chr
        mapper.persistentState = state.mapperState
        restoreCycles(state.cycles)
    }

    internal func restoreCycles(_ value: Int) { cycles = value }
}
