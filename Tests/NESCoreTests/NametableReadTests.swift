@testable import NESCore
import Testing

/// Reading the background out of the nametable is how the harness learns room
/// geometry without being told it. The accessor is small, but it sits on top of
/// mirroring, and getting mirroring wrong reads a plausible-looking grid from
/// the wrong half of VRAM — which fails as a wrong route, not as an error.
@Suite("Nametable reading")
struct NametableReadTests {
    /// A mapper that answers only for mirroring, so a test can pick a scheme
    /// MMC1 reaches at runtime without building a cartridge that gets there.
    private final class MirroringMapper: Mapper {
        let mirroring: Mirroring
        private var chr = [UInt8](repeating: 0, count: 0x2000)
        init(_ mirroring: Mirroring) { self.mirroring = mirroring }
        func cpuRead(_: UInt16) -> UInt8? { nil }
        func cpuWrite(_: UInt16, _: UInt8) {}
        func ppuRead(_ address: UInt16) -> UInt8 { chr[Int(address & 0x1FFF)] }
        func ppuWrite(_ address: UInt16, _ value: UInt8) { chr[Int(address & 0x1FFF)] = value }
    }

    /// A PPU alone, so these tests need no ROM and no cartridge.
    private func ppu(mirroring: Mirroring) -> PPU {
        PPU(mapper: MirroringMapper(mirroring))
    }

    @Test("A tile written through the PPU bus reads back at its grid position")
    func roundTripsThroughTheBus() {
        let p = ppu(mirroring: .horizontal)
        // $2000 + row * 32 + column
        p.ppuWrite(0x2000 + 5 * 32 + 9, 0xAB)
        #expect(p.nametableTile(column: 9, row: 5, table: 0) == 0xAB)
    }

    @Test("Column and row are not transposed")
    func columnRowOrder() {
        let p = ppu(mirroring: .horizontal)
        p.ppuWrite(0x2000 + 1 * 32 + 3, 0x11)
        p.ppuWrite(0x2000 + 3 * 32 + 1, 0x22)
        #expect(p.nametableTile(column: 3, row: 1, table: 0) == 0x11)
        #expect(p.nametableTile(column: 1, row: 3, table: 0) == 0x22)
    }

    /// Horizontal mirroring puts tables 0 and 1 in the same 1KB bank, so a
    /// write to one has to be visible through the other.
    @Test("Horizontal mirroring aliases tables 0 and 1")
    func horizontalMirroring() {
        let p = ppu(mirroring: .horizontal)
        p.ppuWrite(0x2000, 0x5A)
        #expect(p.nametableTile(column: 0, row: 0, table: 0) == 0x5A)
        #expect(p.nametableTile(column: 0, row: 0, table: 1) == 0x5A)
        p.ppuWrite(0x2800, 0x77)
        #expect(p.nametableTile(column: 0, row: 0, table: 2) == 0x77)
        #expect(p.nametableTile(column: 0, row: 0, table: 0) == 0x5A)
    }

    /// Vertical mirroring pairs 0 with 2 instead, which is the case that
    /// silently returns the wrong room if the accessor ignores mirroring.
    @Test("Vertical mirroring aliases tables 0 and 2")
    func verticalMirroring() {
        let p = ppu(mirroring: .vertical)
        p.ppuWrite(0x2000, 0x3C)
        #expect(p.nametableTile(column: 0, row: 0, table: 0) == 0x3C)
        #expect(p.nametableTile(column: 0, row: 0, table: 2) == 0x3C)
        p.ppuWrite(0x2400, 0x4D)
        #expect(p.nametableTile(column: 0, row: 0, table: 1) == 0x4D)
        #expect(p.nametableTile(column: 0, row: 0, table: 0) == 0x3C)
    }

    /// MMC1 switches to single-screen mirroring, where every logical table is
    /// the same physical one.
    @Test("Single-screen mirroring aliases every table")
    func singleScreenMirroring() {
        let p = ppu(mirroring: .singleScreenLow)
        p.ppuWrite(0x2C00 + 4, 0x99)
        for table in 0..<4 {
            #expect(p.nametableTile(column: 4, row: 0, table: table) == 0x99)
        }
    }

    /// The nametable the PPU is currently rendering from comes out of the low
    /// two control bits, and a caller that guesses table 0 reads the wrong
    /// screen the moment the game flips them.
    @Test("The active nametable follows the control register")
    func activeTableFollowsControl() {
        let p = ppu(mirroring: .vertical)
        p.control = []
        #expect(p.activeNametable == 0)
        p.control = [.nametableX]
        #expect(p.activeNametable == 1)
        p.control = [.nametableY]
        #expect(p.activeNametable == 2)
        p.control = [.nametableX, .nametableY]
        #expect(p.activeNametable == 3)
    }

    @Test("Out-of-range coordinates read as zero rather than trapping")
    func outOfRangeIsSafe() {
        let p = ppu(mirroring: .horizontal)
        #expect(p.nametableTile(column: -1, row: 0, table: 0) == 0)
        #expect(p.nametableTile(column: 32, row: 0, table: 0) == 0)
        #expect(p.nametableTile(column: 0, row: 30, table: 0) == 0)
    }
}
