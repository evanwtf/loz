/// A cartridge mapper: decodes CPU and PPU addresses that fall into cartridge
/// space, and owns any bank-switching state.
public protocol Mapper: AnyObject {
    /// CPU reads in $4020-$FFFF. Returns nil if the mapper does not respond,
    /// letting the bus supply open-bus behaviour.
    func cpuRead(_ address: UInt16) -> UInt8?
    /// CPU writes in $4020-$FFFF.
    func cpuWrite(_ address: UInt16, _ value: UInt8)

    /// PPU reads/writes in $0000-$1FFF (pattern tables).
    func ppuRead(_ address: UInt16) -> UInt8
    func ppuWrite(_ address: UInt16, _ value: UInt8)

    /// Current mirroring; MMC1 can change this at runtime.
    var mirroring: Mirroring { get }

    /// PRG bank currently visible at $8000-$BFFF.
    ///
    /// Decompiled routines are keyed by (bank, address) because a bare address
    /// is ambiguous under banking, so the dispatcher needs to ask the mapper
    /// what is mapped right now.
    var currentPRGBank: Int { get }

    /// Notification that the PPU drove a pattern-table address.
    ///
    /// MMC3 counts scanlines by watching A12 rise, which is how Super Mario
    /// Bros. 3 splits its status bar. Mappers without an IRQ ignore this.
    func ppuAddressChanged(_ address: UInt16)

    /// True while the mapper is asserting the CPU's IRQ line.
    var irqAsserted: Bool { get }

    /// Bank-selection registers, for save states. Mappers with no state — NROM —
    /// use the empty default.
    var persistentState: [UInt8] { get set }
}

public extension Mapper {
    var currentPRGBank: Int { 0 }
    func ppuAddressChanged(_: UInt16) {}
    var irqAsserted: Bool { false }
    var persistentState: [UInt8] {
        get { [] }
        set {}
    }
}

/// Mapper 0. No banking — useful as a sanity target for test ROMs.
public final class NROM: Mapper {
    private let cartridge: Cartridge
    public var mirroring: Mirroring { cartridge.initialMirroring }

    public init(cartridge: Cartridge) {
        self.cartridge = cartridge
    }

    public func cpuRead(_ address: UInt16) -> UInt8? {
        switch address {
        case 0x6000...0x7FFF:
            return cartridge.prgRAM[Int(address - 0x6000)]
        case 0x8000...0xFFFF:
            // 16KB carts mirror the single bank across both slots.
            let mask = cartridge.prgROM.count - 1
            return cartridge.prgROM[Int(address - 0x8000) & mask]
        default:
            return nil
        }
    }

    public func cpuWrite(_ address: UInt16, _ value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            cartridge.prgRAM[Int(address - 0x6000)] = value
        }
    }

    public func ppuRead(_ address: UInt16) -> UInt8 {
        cartridge.chr[Int(address) & 0x1FFF]
    }

    public func ppuWrite(_ address: UInt16, _ value: UInt8) {
        guard cartridge.usesCHRRAM else { return }
        cartridge.chr[Int(address) & 0x1FFF] = value
    }
}
