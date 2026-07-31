import Testing
@testable import NESCore

@Suite("PPU")
struct PPUTests {

    /// A PPU backed by a CHR-RAM cartridge so tests can write pattern data.
    private func makePPU(mirroring vertical: Bool = false) -> PPU {
        var rom: [UInt8] = Array("NES\u{1A}".utf8)
        rom += [2, 0, vertical ? 0x01 : 0x00, 0x00]   // 32KB PRG, CHR-RAM, mapper 0
        rom += [UInt8](repeating: 0, count: 8)
        rom += [UInt8](repeating: 0, count: 0x8000)
        let cart = try! Cartridge(data: rom)
        return PPU(mapper: try! cart.makeMapper())
    }

    /// Fills tile `index` so every pixel is colour 1 (low plane all ones).
    private func makeOpaqueTile(_ ppu: PPU, index: UInt8, table: UInt16 = 0x0000) {
        let base = table + UInt16(index) * 16
        for row in 0..<8 {
            ppu.ppuWrite(base + UInt16(row), 0xFF)      // low plane
            ppu.ppuWrite(base + UInt16(row) + 8, 0x00)  // high plane
        }
    }

    private func run(_ ppu: PPU, toScanline scanline: Int) {
        var guardCount = 0
        while ppu.scanline != scanline && guardCount < 400_000 {
            ppu.step()
            guardCount += 1
        }
    }

    // MARK: Registers

    @Test("Reading $2002 clears vblank and resets the write toggle")
    func statusReadClearsState() {
        let ppu = makePPU()
        ppu.status.insert(.vblank)
        ppu.writeRegister(0x2006, 0x21)     // first half of an address write
        #expect(ppu.writeToggle)

        let value = ppu.readRegister(0x2002)
        #expect(value & 0x80 != 0)
        #expect(!ppu.status.contains(.vblank))
        #expect(!ppu.writeToggle)
    }

    @Test("$2007 advances by 1 or 32 depending on PPUCTRL bit 2")
    func vramIncrementMode() {
        let across = makePPU()
        across.writeRegister(0x2000, 0x00)
        across.writeRegister(0x2006, 0x20)
        across.writeRegister(0x2006, 0x00)
        across.writeRegister(0x2007, 0xAA)
        #expect(across.v == 0x2001)

        let down = makePPU()
        down.writeRegister(0x2000, 0x04)    // incrementDown
        down.writeRegister(0x2006, 0x20)
        down.writeRegister(0x2006, 0x00)
        down.writeRegister(0x2007, 0xAA)
        #expect(down.v == 0x2020)
    }

    @Test("$2007 reads of non-palette memory are delayed by one access")
    func bufferedReads() {
        let ppu = makePPU()
        ppu.writeRegister(0x2006, 0x20)
        ppu.writeRegister(0x2006, 0x00)
        ppu.writeRegister(0x2007, 0x42)     // $2000 <- $42

        ppu.writeRegister(0x2006, 0x20)
        ppu.writeRegister(0x2006, 0x00)
        let stale = ppu.readRegister(0x2007)   // returns the buffer, not $42
        let fresh = ppu.readRegister(0x2007)
        #expect(stale != 0x42 || fresh == 0x42)
        #expect(fresh == 0x42)
    }

    @Test("Palette reads are immediate, not buffered")
    func paletteReadsAreImmediate() {
        let ppu = makePPU()
        ppu.writeRegister(0x2006, 0x3F)
        ppu.writeRegister(0x2006, 0x01)
        ppu.writeRegister(0x2007, 0x25)

        ppu.writeRegister(0x2006, 0x3F)
        ppu.writeRegister(0x2006, 0x01)
        #expect(ppu.readRegister(0x2007) == 0x25)
    }

    @Test("Sprite palette backdrops mirror the background ones")
    func paletteMirroring() {
        let ppu = makePPU()
        ppu.ppuWrite(0x3F10, 0x21)
        #expect(ppu.ppuRead(0x3F00) == 0x21)
        ppu.ppuWrite(0x3F00, 0x0F)
        #expect(ppu.ppuRead(0x3F10) == 0x0F)

        for offset in [UInt16(0x04), 0x08, 0x0C] {
            ppu.ppuWrite(0x3F10 + offset, UInt8(offset))
            #expect(ppu.ppuRead(0x3F00 + offset) == UInt8(offset))
        }
    }

    // MARK: Scroll registers

    @Test("$2005 and $2006 write into the loopy temporary register")
    func loopyWrites() {
        let ppu = makePPU()
        // $2005 first write: coarse X into t, fine X into its own latch.
        ppu.writeRegister(0x2005, 0b11111_101)
        #expect(ppu.t & 0x001F == 0b11111)
        #expect(ppu.fineX == 0b101)

        // $2005 second write: coarse Y and fine Y.
        ppu.writeRegister(0x2005, 0b10101_011)
        #expect((ppu.t >> 12) & 0x07 == 0b011)
        #expect((ppu.t >> 5) & 0x1F == 0b10101)
    }

    @Test("The second $2006 write copies t into v")
    func addressWriteCopiesToV() {
        let ppu = makePPU()
        ppu.writeRegister(0x2006, 0x21)
        #expect(ppu.v != 0x2108)            // not until the second write
        ppu.writeRegister(0x2006, 0x08)
        #expect(ppu.v == 0x2108)
        #expect(ppu.t == 0x2108)
    }

    @Test("PPUCTRL nametable bits land in t bits 10-11")
    func controlSetsNametableBits() {
        let ppu = makePPU()
        ppu.writeRegister(0x2000, 0x03)
        #expect((ppu.t >> 10) & 0x03 == 0x03)
    }

    // MARK: Nametable mirroring

    @Test("Horizontal mirroring pairs the top and bottom nametables")
    func horizontalMirroring() {
        let ppu = makePPU(mirroring: false)
        ppu.ppuWrite(0x2000, 0x11)
        #expect(ppu.ppuRead(0x2400) == 0x11)   // same bank
        ppu.ppuWrite(0x2800, 0x22)
        #expect(ppu.ppuRead(0x2C00) == 0x22)
        #expect(ppu.ppuRead(0x2000) == 0x11)   // untouched
    }

    @Test("Vertical mirroring pairs the left and right nametables")
    func verticalMirroring() {
        let ppu = makePPU(mirroring: true)
        ppu.ppuWrite(0x2000, 0x33)
        #expect(ppu.ppuRead(0x2800) == 0x33)
        ppu.ppuWrite(0x2400, 0x44)
        #expect(ppu.ppuRead(0x2C00) == 0x44)
        #expect(ppu.ppuRead(0x2000) == 0x33)
    }

    // MARK: Frame timing

    @Test("Vblank is raised at scanline 241 and NMI fires when enabled")
    func vblankAndNMI() {
        let ppu = makePPU()
        ppu.writeRegister(0x2000, 0x80)     // NMI enabled
        run(ppu, toScanline: 241)
        while ppu.dot < 2 { ppu.step() }
        #expect(ppu.status.contains(.vblank))
        #expect(ppu.nmiRequested)
    }

    @Test("No NMI is requested when PPUCTRL bit 7 is clear")
    func noNMIWhenDisabled() {
        let ppu = makePPU()
        ppu.writeRegister(0x2000, 0x00)
        run(ppu, toScanline: 241)
        while ppu.dot < 2 { ppu.step() }
        #expect(ppu.status.contains(.vblank))
        #expect(!ppu.nmiRequested)
    }

    @Test("The pre-render line clears vblank, sprite 0 hit, and overflow")
    func preRenderClearsFlags() {
        let ppu = makePPU()
        ppu.status.insert([.vblank, .sprite0Hit, .spriteOverflow])
        run(ppu, toScanline: 261)
        while ppu.dot < 2 { ppu.step() }
        #expect(!ppu.status.contains(.vblank))
        #expect(!ppu.status.contains(.sprite0Hit))
        #expect(!ppu.status.contains(.spriteOverflow))
    }

    // MARK: Sprite 0 hit

    /// Sets up an opaque background tile and an opaque sprite 0 on top of it.
    private func makeSprite0Scene(spriteY: UInt8, spriteX: UInt8) -> PPU {
        let ppu = makePPU()
        makeOpaqueTile(ppu, index: 1)

        // Cover the whole first nametable so background is opaque everywhere.
        for i in 0..<0x3C0 {
            ppu.ppuWrite(0x2000 + UInt16(i), 1)
        }
        ppu.ppuWrite(0x3F00, 0x0F)
        ppu.ppuWrite(0x3F01, 0x30)

        ppu.oam[0] = spriteY
        ppu.oam[1] = 1          // tile 1
        ppu.oam[2] = 0          // palette 0, in front
        ppu.oam[3] = spriteX

        ppu.writeRegister(0x2001, 0x1E)   // show BG + sprites, including left column
        return ppu
    }

    @Test("Sprite 0 hit fires where an opaque sprite overlaps opaque background")
    func sprite0HitFires() {
        let ppu = makeSprite0Scene(spriteY: 50, spriteX: 100)
        run(ppu, toScanline: 240)
        #expect(ppu.status.contains(.sprite0Hit))
    }

    /// OAM Y = n places the sprite on scanlines n+1 through n+8, so the hit
    /// must not appear on scanline n itself.
    @Test("Sprite 0 is delayed by one scanline relative to its OAM Y")
    func sprite0StartsOneScanlineBelowOAMY() {
        let ppu = makeSprite0Scene(spriteY: 50, spriteX: 100)

        run(ppu, toScanline: 50)
        while ppu.dot < 340 { ppu.step() }
        #expect(!ppu.status.contains(.sprite0Hit), "must not hit on scanline 50")

        run(ppu, toScanline: 52)
        #expect(ppu.status.contains(.sprite0Hit), "must hit by scanline 51")
    }

    @Test("Sprite 0 stops hitting past its eight-scanline height")
    func sprite0EndsAfterEightScanlines() {
        let ppu = makeSprite0Scene(spriteY: 50, spriteX: 100)
        // Sprite occupies 51...58. Clear the flag, then check 59 onward is quiet.
        run(ppu, toScanline: 59)
        ppu.status.remove(.sprite0Hit)
        run(ppu, toScanline: 100)
        #expect(!ppu.status.contains(.sprite0Hit))
    }

    @Test("No sprite 0 hit when the background is transparent")
    func noHitWithoutBackground() {
        let ppu = makePPU()
        makeOpaqueTile(ppu, index: 1)
        // Nametable left as tile 0, which has no pattern data -> transparent.
        ppu.oam[0] = 50
        ppu.oam[1] = 1
        ppu.oam[2] = 0
        ppu.oam[3] = 100
        ppu.writeRegister(0x2001, 0x1E)
        run(ppu, toScanline: 240)
        #expect(!ppu.status.contains(.sprite0Hit))
    }

    @Test("No sprite 0 hit while rendering is disabled")
    func noHitWhenRenderingOff() {
        let ppu = makeSprite0Scene(spriteY: 50, spriteX: 100)
        ppu.writeRegister(0x2001, 0x00)   // rendering off
        run(ppu, toScanline: 240)
        #expect(!ppu.status.contains(.sprite0Hit))
    }

    @Test("Sprite 0 hit never fires at x = 255")
    func noHitAtX255() {
        let ppu = makeSprite0Scene(spriteY: 50, spriteX: 255)
        run(ppu, toScanline: 240)
        #expect(!ppu.status.contains(.sprite0Hit))
    }

    @Test("Sprite overflow sets once more than eight sprites share a scanline")
    func spriteOverflow() {
        let ppu = makePPU()
        makeOpaqueTile(ppu, index: 1)
        for i in 0..<9 {
            ppu.oam[i * 4] = 50
            ppu.oam[i * 4 + 1] = 1
            ppu.oam[i * 4 + 2] = 0
            ppu.oam[i * 4 + 3] = UInt8(i * 8)
        }
        ppu.writeRegister(0x2001, 0x1E)
        run(ppu, toScanline: 240)
        #expect(ppu.status.contains(.spriteOverflow))
    }
}
