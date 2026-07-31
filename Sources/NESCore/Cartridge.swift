import Foundation

/// How the PPU's two physical 1KB nametables are mapped across the four
/// logical nametable slots at $2000/$2400/$2800/$2C00.
public enum Mirroring: Sendable {
    case horizontal
    case vertical
    case singleScreenLow
    case singleScreenHigh
    case fourScreen

    /// Maps a PPU nametable address ($2000-$2FFF) to an offset in the 2KB VRAM.
    @inline(__always)
    func vramIndex(for address: UInt16) -> Int {
        let addr = Int(address & 0x0FFF)
        let table = addr / 0x400
        let offset = addr % 0x400
        switch self {
        case .horizontal:
            // Tables 0,1 -> bank 0;  tables 2,3 -> bank 1
            return (table / 2) * 0x400 + offset
        case .vertical:
            // Tables 0,2 -> bank 0;  tables 1,3 -> bank 1
            return (table % 2) * 0x400 + offset
        case .singleScreenLow:
            return offset
        case .singleScreenHigh:
            return 0x400 + offset
        case .fourScreen:
            // Requires cartridge VRAM; unsupported for now, fall back to the
            // 2KB window so behaviour stays defined.
            return addr % 0x800
        }
    }
}

public enum CartridgeError: Error, CustomStringConvertible {
    case notINES
    case truncated(expected: Int, got: Int)
    case unsupportedMapper(Int)

    public var description: String {
        switch self {
        case .notINES:
            return "Not an iNES file (missing 'NES\\x1A' magic)."
        case .truncated(let expected, let got):
            return "ROM truncated: header declares \(expected) bytes of data, file has \(got)."
        case .unsupportedMapper(let n):
            return "Unsupported mapper \(n). Only mapper 0 (NROM) and 1 (MMC1) are implemented."
        }
    }
}

/// A parsed iNES cartridge image plus its volatile and battery-backed RAM.
public final class Cartridge {
    public let prgROM: [UInt8]
    /// Pattern tables. Either ROM from the file, or 8KB of RAM when the header
    /// declares zero CHR banks (as Zelda's SNROM board does).
    public internal(set) var chr: [UInt8]
    public let usesCHRRAM: Bool

    /// 8KB of work RAM at $6000-$7FFF. Battery-backed on Zelda — this is the
    /// array that gets written out as the `.sav` file.
    public var prgRAM: [UInt8]
    public let hasBattery: Bool

    public let mapperNumber: Int
    public let initialMirroring: Mirroring

    public var prgBankCount16K: Int { prgROM.count / 0x4000 }
    public var chrBankCount8K: Int { max(chr.count / 0x2000, 1) }

    public init(data: [UInt8]) throws {
        guard data.count >= 16,
              data[0] == 0x4E, data[1] == 0x45, data[2] == 0x53, data[3] == 0x1A
        else { throw CartridgeError.notINES }

        let prgBanks = Int(data[4])
        let chrBanks = Int(data[5])
        let flags6 = data[6]
        var flags7 = data[7]

        // Some old dumpers scribbled ASCII into bytes 7-15 ("DiskDude!"), which
        // corrupts the high mapper nibble. If the tail is non-zero, distrust it.
        if data.count >= 16, data[12...15].contains(where: { $0 != 0 }) {
            flags7 = 0
        }

        let hasTrainer = (flags6 & 0x04) != 0
        self.hasBattery = (flags6 & 0x02) != 0
        self.mapperNumber = Int((flags6 >> 4) | (flags7 & 0xF0))

        if (flags6 & 0x08) != 0 {
            self.initialMirroring = .fourScreen
        } else {
            self.initialMirroring = (flags6 & 0x01) != 0 ? .vertical : .horizontal
        }

        let prgSize = prgBanks * 0x4000
        let chrSize = chrBanks * 0x2000
        var offset = 16 + (hasTrainer ? 512 : 0)

        let needed = offset + prgSize + chrSize
        guard data.count >= needed else {
            throw CartridgeError.truncated(expected: needed, got: data.count)
        }

        self.prgROM = Array(data[offset ..< offset + prgSize])
        offset += prgSize

        if chrSize == 0 {
            // Zero CHR banks means the board carries 8KB of CHR-RAM instead.
            self.chr = [UInt8](repeating: 0, count: 0x2000)
            self.usesCHRRAM = true
        } else {
            self.chr = Array(data[offset ..< offset + chrSize])
            self.usesCHRRAM = false
        }

        self.prgRAM = [UInt8](repeating: 0, count: 0x2000)
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: [UInt8](Data(contentsOf: url)))
    }

    public func makeMapper() throws -> Mapper {
        switch mapperNumber {
        case 0: return NROM(cartridge: self)
        case 1: return MMC1(cartridge: self)
        default: throw CartridgeError.unsupportedMapper(mapperNumber)
        }
    }

    /// Human-readable summary, handy for the CLI harness.
    public var summary: String {
        """
        Mapper:    \(mapperNumber)
        PRG-ROM:   \(prgROM.count / 1024) KB (\(prgBankCount16K) x 16KB)
        CHR:       \(chr.count / 1024) KB \(usesCHRRAM ? "RAM" : "ROM")
        Mirroring: \(initialMirroring)
        Battery:   \(hasBattery ? "yes" : "no")
        """
    }
}
