/// Ricoh 2C02 picture processing unit.
///
/// Dot-based: `step()` advances one PPU cycle, and the CPU runs one cycle for
/// every three of these. The scroll registers follow the standard "loopy"
/// model (v/t/x/w), which is the only formulation that gets mid-frame scroll
/// splits right — and Zelda's status bar is exactly such a split.
public final class PPU {

    // MARK: Register bitfields

    public struct Control: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let nametableX      = Control(rawValue: 1 << 0)
        public static let nametableY      = Control(rawValue: 1 << 1)
        /// VRAM address advances by 32 instead of 1 after each $2007 access.
        public static let incrementDown   = Control(rawValue: 1 << 2)
        public static let spritePatternHi = Control(rawValue: 1 << 3)
        public static let bgPatternHi     = Control(rawValue: 1 << 4)
        public static let tallSprites     = Control(rawValue: 1 << 5)
        public static let masterSlave     = Control(rawValue: 1 << 6)
        public static let nmiEnabled      = Control(rawValue: 1 << 7)
    }

    public struct Mask: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let greyscale       = Mask(rawValue: 1 << 0)
        public static let showBGLeft      = Mask(rawValue: 1 << 1)
        public static let showSpritesLeft = Mask(rawValue: 1 << 2)
        public static let showBG          = Mask(rawValue: 1 << 3)
        public static let showSprites     = Mask(rawValue: 1 << 4)
        public static let emphasizeRed    = Mask(rawValue: 1 << 5)
        public static let emphasizeGreen  = Mask(rawValue: 1 << 6)
        public static let emphasizeBlue   = Mask(rawValue: 1 << 7)
    }

    public struct Status: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let spriteOverflow = Status(rawValue: 1 << 5)
        public static let sprite0Hit     = Status(rawValue: 1 << 6)
        public static let vblank         = Status(rawValue: 1 << 7)
    }

    // MARK: State

    public var control: Control = []
    public var mask: Mask = []
    public var status: Status = []

    /// 2KB of nametable RAM. How it maps into $2000-$2FFF depends on mirroring.
    public internal(set) var vram = [UInt8](repeating: 0, count: 0x800)
    public internal(set) var paletteRAM = [UInt8](repeating: 0, count: 32)
    public internal(set) var oam = [UInt8](repeating: 0, count: 256)
    public var oamAddress: UInt8 = 0

    // Loopy scroll registers.
    /// Current VRAM address (15 bits): `yyy NN YYYYY XXXXX`.
    var v: UInt16 = 0
    /// Temporary address / topmost scroll latch.
    var t: UInt16 = 0
    /// Fine X scroll (3 bits).
    var fineX: UInt8 = 0
    /// First/second write toggle, shared by $2005 and $2006.
    var writeToggle = false

    /// $2007 reads of non-palette memory are delayed by one access.
    private var readBuffer: UInt8 = 0

    /// Last value on the PPU bus, returned for the unused bits of $2002.
    private var openBus: UInt8 = 0

    // Timing.
    public private(set) var scanline = 261
    public private(set) var dot = 0
    public private(set) var frame = 0

    /// Set when a frame finishes; the driver clears it.
    public var frameComplete = false
    /// Set when vblank starts with NMI enabled; the driver clears it.
    public var nmiRequested = false

    /// 256x240 RGBA output.
    public private(set) var framebuffer = [UInt32](repeating: 0, count: 256 * 240)

    private let mapper: Mapper

    /// Debug hook: every write that reaches palette memory, with the resolved
    /// address. Used to diagnose transfers that land at the wrong offset.
    public var onPaletteWrite: ((UInt16, UInt8) -> Void)?

    public init(mapper: Mapper) {
        self.mapper = mapper
    }

    // MARK: Background pipeline

    // Latches for the tile currently being fetched.
    private var ntLatch: UInt8 = 0
    private var atLatch: UInt8 = 0
    private var bgLoLatch: UInt8 = 0
    private var bgHiLatch: UInt8 = 0

    // 16-bit shift registers; the high byte is the tile being displayed and the
    // low byte the one queued behind it.
    private var bgShiftLo: UInt16 = 0
    private var bgShiftHi: UInt16 = 0
    private var atShiftLo: UInt16 = 0
    private var atShiftHi: UInt16 = 0

    // MARK: Sprite pipeline

    private struct SpriteSlot {
        var x: UInt8 = 0
        var patternLo: UInt8 = 0
        var patternHi: UInt8 = 0
        var palette: UInt8 = 0
        var behindBackground = false
        /// True when this slot holds OAM sprite 0, which drives the hit flag.
        var isSpriteZero = false
    }

    private var spriteSlots = [SpriteSlot](repeating: SpriteSlot(), count: 8)
    private var spriteCount = 0

    private var renderingEnabled: Bool {
        mask.contains(.showBG) || mask.contains(.showSprites)
    }

    // MARK: PPU memory

    func ppuRead(_ address: UInt16) -> UInt8 {
        let addr = address & 0x3FFF
        switch addr {
        case 0x0000...0x1FFF:
            return mapper.ppuRead(addr)
        case 0x2000...0x3EFF:
            return vram[mapper.mirroring.vramIndex(for: addr & 0x2FFF)]
        default:
            return paletteRAM[Int(paletteIndex(addr))]
        }
    }

    func ppuWrite(_ address: UInt16, _ value: UInt8) {
        let addr = address & 0x3FFF
        switch addr {
        case 0x0000...0x1FFF:
            mapper.ppuWrite(addr, value)
        case 0x2000...0x3EFF:
            vram[mapper.mirroring.vramIndex(for: addr & 0x2FFF)] = value
        default:
            onPaletteWrite?(addr, value)
            paletteRAM[Int(paletteIndex(addr))] = value
        }
    }

    /// $3F00-$3F1F mirrored every 32 bytes, and the sprite backdrop entries
    /// $3F10/$14/$18/$1C alias the background ones.
    private func paletteIndex(_ address: UInt16) -> UInt16 {
        var index = address & 0x1F
        if index & 0x13 == 0x10 { index &= ~0x10 }
        return index
    }

    // MARK: CPU-facing registers

    public func readRegister(_ address: UInt16) -> UInt8 {
        switch address & 7 {
        case 2:
            // Unused bits read back as whatever was last on the bus.
            let value = status.rawValue | (openBus & 0x1F)
            status.remove(.vblank)
            writeToggle = false
            openBus = value
            return value

        case 4:
            let value = oam[Int(oamAddress)]
            openBus = value
            return value

        case 7:
            let addr = v & 0x3FFF
            var value = ppuRead(addr)
            if addr < 0x3F00 {
                // Non-palette reads return the *previous* buffered byte.
                let buffered = readBuffer
                readBuffer = value
                value = buffered
            } else {
                // Palette reads are immediate, but still refill the buffer from
                // the nametable underneath.
                readBuffer = ppuRead(addr & 0x2FFF)
            }
            v &+= control.contains(.incrementDown) ? 32 : 1
            openBus = value
            return value

        default:
            // $2000/$2001/$2003/$2005/$2006 are write-only.
            return openBus
        }
    }

    public func writeRegister(_ address: UInt16, _ value: UInt8) {
        openBus = value
        switch address & 7 {
        case 0:
            control = Control(rawValue: value)
            // t: ...GH.. ........ <- d: ......GH
            t = (t & 0xF3FF) | (UInt16(value & 0x03) << 10)

        case 1:
            mask = Mask(rawValue: value)

        case 3:
            oamAddress = value

        case 4:
            oam[Int(oamAddress)] = value
            oamAddress &+= 1

        case 5:
            if !writeToggle {
                // t: ....... ...ABCDE <- d: ABCDE...   x: FGH <- d: .....FGH
                t = (t & 0xFFE0) | (UInt16(value) >> 3)
                fineX = value & 0x07
            } else {
                // t: FGH..AB CDE..... <- d: ABCDEFGH
                t = (t & 0x8FFF) | (UInt16(value & 0x07) << 12)
                t = (t & 0xFC1F) | (UInt16(value & 0xF8) << 2)
            }
            writeToggle.toggle()

        case 6:
            if !writeToggle {
                // t: .CDEFGH ........ <- d: ..CDEFGH, and bit 14 is cleared.
                t = (t & 0x00FF) | (UInt16(value & 0x3F) << 8)
            } else {
                t = (t & 0xFF00) | UInt16(value)
                v = t
            }
            writeToggle.toggle()

        case 7:
            ppuWrite(v & 0x3FFF, value)
            v &+= control.contains(.incrementDown) ? 32 : 1

        default:
            break
        }
    }

    /// Called by OAM DMA. Writes land relative to the current OAM address.
    public func writeOAM(_ offset: Int, _ value: UInt8) {
        oam[Int(oamAddress &+ UInt8(truncatingIfNeeded: offset))] = value
    }

    // MARK: Scroll address arithmetic

    private func incrementCoarseX() {
        guard renderingEnabled else { return }
        if v & 0x001F == 31 {
            v &= ~0x001F            // coarse X = 0
            v ^= 0x0400             // flip horizontal nametable
        } else {
            v &+= 1
        }
    }

    private func incrementY() {
        guard renderingEnabled else { return }
        if v & 0x7000 != 0x7000 {
            v &+= 0x1000            // fine Y++
        } else {
            v &= ~0x7000            // fine Y = 0
            var coarseY = (v & 0x03E0) >> 5
            if coarseY == 29 {
                coarseY = 0
                v ^= 0x0800         // flip vertical nametable
            } else if coarseY == 31 {
                coarseY = 0         // out-of-bounds row: wrap without flipping
            } else {
                coarseY += 1
            }
            v = (v & ~0x03E0) | (coarseY << 5)
        }
    }

    private func copyHorizontalBits() {
        guard renderingEnabled else { return }
        // v: ....A.. ...BCDEF <- t
        v = (v & 0xFBE0) | (t & 0x041F)
    }

    private func copyVerticalBits() {
        guard renderingEnabled else { return }
        // v: GHIA.BC DEF..... <- t
        v = (v & 0x841F) | (t & 0x7BE0)
    }

    // MARK: Background fetches

    private func loadShiftRegisters() {
        bgShiftLo = (bgShiftLo & 0xFF00) | UInt16(bgLoLatch)
        bgShiftHi = (bgShiftHi & 0xFF00) | UInt16(bgHiLatch)
        // The 2-bit attribute is smeared across all eight pixels of the tile.
        atShiftLo = (atShiftLo & 0xFF00) | (atLatch & 0b01 != 0 ? 0x00FF : 0x0000)
        atShiftHi = (atShiftHi & 0xFF00) | (atLatch & 0b10 != 0 ? 0x00FF : 0x0000)
    }

    private func shiftRegisters() {
        guard mask.contains(.showBG) else { return }
        bgShiftLo <<= 1
        bgShiftHi <<= 1
        atShiftLo <<= 1
        atShiftHi <<= 1
    }

    private func fetchBackground() {
        switch dot % 8 {
        case 1:
            loadShiftRegisters()
            ntLatch = ppuRead(0x2000 | (v & 0x0FFF))

        case 3:
            // One attribute byte covers a 4x4 tile area; pick the right one.
            let addr = 0x23C0
                | (v & 0x0C00)
                | ((v >> 4) & 0x38)
                | ((v >> 2) & 0x07)
            var attr = ppuRead(addr)
            // Then select the 2-bit quadrant within that byte.
            let shift = UInt8(((v >> 4) & 0x04) | (v & 0x02))
            attr >>= shift
            atLatch = attr & 0x03

        case 5:
            let fineY = (v >> 12) & 0x07
            let base: UInt16 = control.contains(.bgPatternHi) ? 0x1000 : 0x0000
            bgLoLatch = ppuRead(base + UInt16(ntLatch) * 16 + fineY)

        case 7:
            let fineY = (v >> 12) & 0x07
            let base: UInt16 = control.contains(.bgPatternHi) ? 0x1000 : 0x0000
            bgHiLatch = ppuRead(base + UInt16(ntLatch) * 16 + fineY + 8)

        case 0:
            incrementCoarseX()

        default:
            break
        }
    }

    // MARK: Sprite evaluation

    /// Gathers up to 8 sprites for `targetScanline` and pre-fetches their
    /// pattern bytes. Real hardware spreads this across dots 65-256; doing it
    /// in one go is indistinguishable unless a game rewrites OAM mid-scanline.
    private func evaluateSprites(for targetScanline: Int) {
        spriteCount = 0
        guard renderingEnabled else { return }

        let height = control.contains(.tallSprites) ? 16 : 8

        for index in 0..<64 {
            let base = index * 4
            let spriteY = Int(oam[base])
            // OAM stores Y minus one: a sprite at Y occupies scanlines
            // Y+1 through Y+height, so the pattern row lags by one.
            let row = targetScanline - spriteY - 1
            guard row >= 0 && row < height else { continue }

            if spriteCount == 8 {
                status.insert(.spriteOverflow)
                break
            }

            let tile = oam[base + 1]
            let attributes = oam[base + 2]
            let flipH = attributes & 0x40 != 0
            let flipV = attributes & 0x80 != 0
            let fineRow = flipV ? (height - 1 - row) : row

            let patternAddress: UInt16
            if control.contains(.tallSprites) {
                // 8x16: bit 0 of the tile index selects the pattern table and
                // the second tile follows the first.
                let table: UInt16 = (tile & 1) != 0 ? 0x1000 : 0x0000
                let baseTile = UInt16(tile & 0xFE)
                let tileOffset = UInt16(fineRow >= 8 ? 1 : 0)
                patternAddress = table
                    + (baseTile + tileOffset) * 16
                    + UInt16(fineRow & 0x07)
            } else {
                let table: UInt16 = control.contains(.spritePatternHi) ? 0x1000 : 0x0000
                patternAddress = table + UInt16(tile) * 16 + UInt16(fineRow)
            }

            var lo = ppuRead(patternAddress)
            var hi = ppuRead(patternAddress + 8)
            if flipH {
                lo = Self.reverseBits(lo)
                hi = Self.reverseBits(hi)
            }

            spriteSlots[spriteCount] = SpriteSlot(
                x: oam[base + 3],
                patternLo: lo,
                patternHi: hi,
                palette: attributes & 0x03,
                behindBackground: attributes & 0x20 != 0,
                isSpriteZero: index == 0)
            spriteCount += 1
        }
    }

    private static func reverseBits(_ value: UInt8) -> UInt8 {
        var v = value
        v = (v & 0xF0) >> 4 | (v & 0x0F) << 4
        v = (v & 0xCC) >> 2 | (v & 0x33) << 2
        v = (v & 0xAA) >> 1 | (v & 0x55) << 1
        return v
    }

    // MARK: Pixel composition

    private func renderPixel() {
        let x = dot - 1
        guard x >= 0, x < 256, scanline >= 0, scanline < 240 else { return }

        // Background.
        var bgPixel: UInt8 = 0
        var bgPalette: UInt8 = 0
        if mask.contains(.showBG) && (x >= 8 || mask.contains(.showBGLeft)) {
            let bit = UInt16(0x8000) >> UInt16(fineX)
            let lo: UInt8 = (bgShiftLo & bit) != 0 ? 1 : 0
            let hi: UInt8 = (bgShiftHi & bit) != 0 ? 1 : 0
            bgPixel = (hi << 1) | lo
            let paLo: UInt8 = (atShiftLo & bit) != 0 ? 1 : 0
            let paHi: UInt8 = (atShiftHi & bit) != 0 ? 1 : 0
            bgPalette = (paHi << 1) | paLo
        }

        // Sprites — lowest OAM index wins among overlapping opaque pixels.
        var spritePixel: UInt8 = 0
        var spritePalette: UInt8 = 0
        var spriteBehind = false
        var spriteIsZero = false

        if mask.contains(.showSprites) && (x >= 8 || mask.contains(.showSpritesLeft)) {
            for i in 0..<spriteCount {
                let sprite = spriteSlots[i]
                let offset = x - Int(sprite.x)
                guard offset >= 0 && offset < 8 else { continue }

                let bit = UInt8(0x80) >> UInt8(offset)
                let lo: UInt8 = (sprite.patternLo & bit) != 0 ? 1 : 0
                let hi: UInt8 = (sprite.patternHi & bit) != 0 ? 1 : 0
                let pixel = (hi << 1) | lo
                guard pixel != 0 else { continue }

                spritePixel = pixel
                spritePalette = sprite.palette
                spriteBehind = sprite.behindBackground
                spriteIsZero = sprite.isSpriteZero
                break
            }
        }

        // Sprite 0 hit: an opaque sprite-0 pixel over an opaque background
        // pixel. This is the signal Zelda uses to split its status bar, so the
        // exact conditions matter — including that it never fires at x = 255.
        if spriteIsZero && spritePixel != 0 && bgPixel != 0
            && mask.contains(.showBG) && mask.contains(.showSprites)
            && x != 255
            && (x >= 8 || (mask.contains(.showBGLeft) && mask.contains(.showSpritesLeft))) {
            status.insert(.sprite0Hit)
        }

        // Priority multiplexer.
        var paletteAddress: UInt16 = 0x3F00
        if bgPixel == 0 && spritePixel == 0 {
            paletteAddress = 0x3F00                     // universal backdrop
        } else if bgPixel == 0 {
            paletteAddress = 0x3F10 + UInt16(spritePalette) * 4 + UInt16(spritePixel)
        } else if spritePixel == 0 {
            paletteAddress = 0x3F00 + UInt16(bgPalette) * 4 + UInt16(bgPixel)
        } else if spriteBehind {
            paletteAddress = 0x3F00 + UInt16(bgPalette) * 4 + UInt16(bgPixel)
        } else {
            paletteAddress = 0x3F10 + UInt16(spritePalette) * 4 + UInt16(spritePixel)
        }

        var entry = ppuRead(paletteAddress) & 0x3F
        if mask.contains(.greyscale) { entry &= 0x30 }
        framebuffer[scanline * 256 + x] = NESPalette.rgba[Int(entry)]
    }

    // MARK: Main clock

    /// Advances the PPU by one dot.
    public func step() {
        let visible = scanline < 240
        let preRender = scanline == 261

        if visible || preRender {
            if preRender && dot == 1 {
                status.remove([.vblank, .sprite0Hit, .spriteOverflow])
            }

            if (dot >= 1 && dot <= 256) || (dot >= 321 && dot <= 336) {
                shiftRegisters()
                fetchBackground()
            }

            if dot == 256 {
                incrementY()
            }
            if dot == 257 {
                loadShiftRegisters()
                copyHorizontalBits()
                // Prepare the next line's sprites.
                evaluateSprites(for: scanline + 1)
            }
            // Vertical scroll is restored repeatedly across this window.
            if preRender && dot >= 280 && dot <= 304 {
                copyVerticalBits()
            }

            if visible {
                renderPixel()
            }
        }

        if scanline == 241 && dot == 1 {
            status.insert(.vblank)
            frameComplete = true
            if control.contains(.nmiEnabled) {
                nmiRequested = true
            }
        }

        // Advance the dot counter.
        dot += 1
        if dot > 340 {
            dot = 0
            scanline += 1
            if scanline > 261 {
                scanline = 0
                frame += 1
            }
        }

        // On odd frames with rendering on, the pre-render line is one dot short.
        if preRender && dot == 340 && frame % 2 == 1 && renderingEnabled {
            dot = 0
            scanline = 0
            frame += 1
        }
    }

    public func reset() {
        control = []
        mask = []
        status = []
        v = 0; t = 0; fineX = 0
        writeToggle = false
        readBuffer = 0
        scanline = 261
        dot = 0
        frame = 0
        frameComplete = false
        nmiRequested = false
    }
}
