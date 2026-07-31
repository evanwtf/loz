@testable import NESCore
import Testing

/// CPU address-space decoding: RAM mirroring, PPU register mirroring, IO, and
/// cartridge routing.
@Suite("System bus")
struct BusTests {
    /// A minimal NROM cartridge so bus tests do not depend on MMC1 banking.
    private func makeNES(prgSize: Int = 0x8000) -> NES {
        var rom: [UInt8] = Array("NES\u{1A}".utf8)
        rom += [UInt8(prgSize / 0x4000), 1, 0x00, 0x00]   // mapper 0, 8KB CHR
        rom += [UInt8](repeating: 0, count: 8)
        rom += [UInt8](repeating: 0xEA, count: prgSize)   // PRG filled with NOP
        rom += [UInt8](repeating: 0, count: 0x2000)       // CHR
        let cart = try! Cartridge(data: rom)
        return try! NES(cartridge: cart)
    }

    // MARK: RAM

    @Test("Internal RAM reads back what was written")
    func ramRoundTrip() {
        let nes = makeNES()
        nes.cpuWrite(0x0000, 0x42)
        nes.cpuWrite(0x07FF, 0x99)
        #expect(nes.cpuRead(0x0000) == 0x42)
        #expect(nes.cpuRead(0x07FF) == 0x99)
    }

    @Test("The 2KB of RAM mirrors three more times up to $1FFF")
    func ramMirroring() {
        let nes = makeNES()
        nes.cpuWrite(0x0000, 0x5A)
        #expect(nes.cpuRead(0x0800) == 0x5A)
        #expect(nes.cpuRead(0x1000) == 0x5A)
        #expect(nes.cpuRead(0x1800) == 0x5A)

        // A write through a mirror lands in the same byte.
        nes.cpuWrite(0x1801, 0x3C)
        #expect(nes.cpuRead(0x0001) == 0x3C)
    }

    // MARK: PPU registers

    @Test("PPU registers mirror every 8 bytes through $3FFF")
    func ppuRegisterMirroring() {
        let nes = makeNES()
        // $2006/$2007 is the VRAM address port; write through a high mirror and
        // read the result back through the canonical address.
        nes.cpuWrite(0x3FF6, 0x21)      // mirrors $2006
        nes.cpuWrite(0x3FF6, 0x08)      // VRAM address = $2108
        nes.cpuWrite(0x3FF7, 0x77)      // mirrors $2007, write data

        nes.cpuWrite(0x2006, 0x21)
        nes.cpuWrite(0x2006, 0x08)
        _ = nes.cpuRead(0x2007)         // buffered read discards first
        #expect(nes.cpuRead(0x2007) == 0x77)
    }

    @Test("Reading $2002 clears the vblank flag and resets the address latch")
    func statusReadSideEffects() {
        let nes = makeNES()
        nes.ppu.status.insert(.vblank)
        let first = nes.cpuRead(0x2002)
        #expect(first & 0x80 != 0)
        let second = nes.cpuRead(0x2002)
        #expect(second & 0x80 == 0)     // cleared by the first read
    }

    // MARK: Cartridge

    @Test("Cartridge space routes to the mapper")
    func cartridgeRouting() {
        let nes = makeNES()
        #expect(nes.cpuRead(0x8000) == 0xEA)
        #expect(nes.cpuRead(0xFFFF) == 0xEA)
    }

    @Test("Work RAM at $6000 reads back")
    func workRAM() {
        let nes = makeNES()
        nes.cpuWrite(0x6000, 0xAB)
        #expect(nes.cpuRead(0x6000) == 0xAB)
    }

    // MARK: Controllers

    @Test("Controller port $4016 strobes both pads and reads pad one")
    func controllerPort() {
        let nes = makeNES()
        nes.controller1.press([.start])
        nes.cpuWrite(0x4016, 1)
        nes.cpuWrite(0x4016, 0)
        // A, B, Select, Start -> the fourth read is Start.
        _ = nes.cpuRead(0x4016)
        _ = nes.cpuRead(0x4016)
        _ = nes.cpuRead(0x4016)
        #expect(nes.cpuRead(0x4016) & 1 == 1)
    }

    @Test("Port $4017 reads controller two")
    func controllerTwoPort() {
        let nes = makeNES()
        nes.controller2.press([.a])
        nes.cpuWrite(0x4016, 1)
        nes.cpuWrite(0x4016, 0)
        #expect(nes.cpuRead(0x4017) & 1 == 1)
        #expect(nes.cpuRead(0x4016) & 1 == 0)   // pad one has nothing pressed
    }

    // MARK: OAM DMA

    @Test("Writing $4014 copies a page into OAM")
    func oamDMACopiesPage() {
        let nes = makeNES()
        // Fill $0300-$03FF in RAM with a recognisable ramp.
        for i in 0..<256 {
            nes.cpuWrite(UInt16(0x0300 + i), UInt8(i))
        }
        nes.cpuWrite(0x4014, 0x03)

        for i in 0..<256 {
            #expect(nes.ppu.oam[i] == UInt8(i))
        }
    }

    @Test("OAM DMA stalls the CPU for 513 cycles")
    func oamDMAStalls() {
        let nes = makeNES()
        nes.cpuWrite(0x4014, 0x03)
        #expect(nes.cpu.stallCycles == 513)
    }

    @Test("OAM DMA honours the current OAM address")
    func oamDMARespectsOAMAddr() {
        let nes = makeNES()
        nes.cpuWrite(0x2003, 0x02)          // OAMADDR = 2
        for i in 0..<256 { nes.cpuWrite(UInt16(0x0300 + i), UInt8(i)) }
        nes.cpuWrite(0x4014, 0x03)
        // Byte 0 of the source lands at OAM[2].
        #expect(nes.ppu.oam[2] == 0)
        #expect(nes.ppu.oam[3] == 1)
    }
}
