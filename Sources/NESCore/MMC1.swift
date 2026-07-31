/// Mapper 1 (MMC1 / SxROM). Zelda's board is SNROM: 128KB PRG, 8KB CHR-RAM,
/// 8KB battery-backed WRAM.
///
/// Registers are written one bit at a time: five consecutive writes to
/// $8000-$FFFF shift bits into an internal register, and the fifth write
/// commits it to whichever of the four control registers the *final* address
/// selects. Writing a value with bit 7 set resets the shift register instead.
public final class MMC1: Mapper {
    private let cartridge: Cartridge

    private var shiftRegister: UInt8 = 0x10   // bit 4 set = "empty" sentinel
    private var control: UInt8 = 0x0C         // PRG mode 3 at power-on
    private var chrBank0: UInt8 = 0
    private var chrBank1: UInt8 = 0
    private var prgBank: UInt8 = 0

    public init(cartridge: Cartridge) {
        self.cartridge = cartridge
    }

    // MARK: Decoded control state

    public var mirroring: Mirroring {
        switch control & 0x03 {
        case 0:  .singleScreenLow
        case 1:  .singleScreenHigh
        case 2:  .vertical
        default: .horizontal
        }
    }

    /// 0,1 = switch 32KB; 2 = fix first bank at $8000; 3 = fix last at $C000.
    private var prgMode: UInt8 { (control >> 2) & 0x03 }
    /// 0 = single 8KB CHR bank; 1 = two independent 4KB banks.
    private var chrMode: UInt8 { (control >> 4) & 0x01 }

    /// On SNROM, bit 4 of the PRG bank register disables WRAM.
    private var prgRAMEnabled: Bool { (prgBank & 0x10) == 0 }

    public var persistentState: [UInt8] {
        get { [shiftRegister, control, chrBank0, chrBank1, prgBank] }
        set {
            guard newValue.count == 5 else { return }
            shiftRegister = newValue[0]
            control = newValue[1]
            chrBank0 = newValue[2]
            chrBank1 = newValue[3]
            prgBank = newValue[4]
        }
    }

    public var currentPRGBank: Int {
        let bankCount = cartridge.prgBankCount16K
        let selected = Int(prgBank & 0x0F) % bankCount
        switch prgMode {
        case 0, 1: return selected & ~1     // 32KB mode: $8000 holds the even bank
        case 2:    return 0                 // first bank fixed at $8000
        default:   return selected          // Zelda's mode: switchable at $8000
        }
    }

    // MARK: CPU

    public func cpuRead(_ address: UInt16) -> UInt8? {
        switch address {
        case 0x6000...0x7FFF:
            guard prgRAMEnabled else { return nil }
            return cartridge.prgRAM[Int(address - 0x6000)]
        case 0x8000...0xFFFF:
            return cartridge.prgROM[prgOffset(for: address)]
        default:
            return nil
        }
    }

    public func cpuWrite(_ address: UInt16, _ value: UInt8) {
        switch address {
        case 0x6000...0x7FFF:
            guard prgRAMEnabled else { return }
            cartridge.prgRAM[Int(address - 0x6000)] = value
        case 0x8000...0xFFFF:
            loadRegister(address, value)
        default:
            break
        }
    }

    private func loadRegister(_ address: UInt16, _ value: UInt8) {
        // Bit 7 set: reset the shift register and force PRG mode 3.
        if value & 0x80 != 0 {
            shiftRegister = 0x10
            control |= 0x0C
            return
        }

        let complete = (shiftRegister & 1) != 0   // sentinel reached bit 0
        shiftRegister = (shiftRegister >> 1) | ((value & 1) << 4)

        guard complete else { return }

        let data = shiftRegister & 0x1F
        switch address {
        case 0x8000...0x9FFF: control  = data
        case 0xA000...0xBFFF: chrBank0 = data
        case 0xC000...0xDFFF: chrBank1 = data
        default:              prgBank  = data
        }
        shiftRegister = 0x10
    }

    /// Maps a CPU address in $8000-$FFFF to an index into PRG-ROM.
    private func prgOffset(for address: UInt16) -> Int {
        let bankCount = cartridge.prgBankCount16K
        let selected = Int(prgBank & 0x0F) % bankCount
        let offsetInBank = Int(address & 0x3FFF)
        let lastBank = bankCount - 1

        let bank: Int
        switch prgMode {
        case 0, 1:
            // 32KB mode: the low bit of the bank number is ignored.
            let base = selected & ~1
            bank = address < 0xC000 ? base : base + 1
        case 2:
            // Fix bank 0 at $8000, switch at $C000.
            bank = address < 0xC000 ? 0 : selected
        default:
            // Fix last bank at $C000, switch at $8000. This is Zelda's mode.
            bank = address < 0xC000 ? selected : lastBank
        }
        return bank * 0x4000 + offsetInBank
    }

    // MARK: PPU

    public func ppuRead(_ address: UInt16) -> UInt8 {
        cartridge.chr[chrOffset(for: address)]
    }

    public func ppuWrite(_ address: UInt16, _ value: UInt8) {
        guard cartridge.usesCHRRAM else { return }
        cartridge.chr[chrOffset(for: address)] = value
    }

    private func chrOffset(for address: UInt16) -> Int {
        let addr = Int(address & 0x1FFF)
        // With 8KB of CHR-RAM there is nothing to bank; the registers are used
        // for PRG-RAM selection on larger boards instead.
        guard !cartridge.usesCHRRAM else { return addr }

        let bankCount4K = max(cartridge.chr.count / 0x1000, 1)
        if chrMode == 0 {
            let bank = (Int(chrBank0) & ~1) % bankCount4K
            return bank * 0x1000 + addr
        } else {
            let bank = addr < 0x1000
                ? Int(chrBank0) % bankCount4K
                : Int(chrBank1) % bankCount4K
            return bank * 0x1000 + (addr & 0x0FFF)
        }
    }
}
