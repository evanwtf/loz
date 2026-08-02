@testable import NESCore
import Testing
import ZeldaGame

/// The playfield geometry and the walkability rule, tested against a synthetic
/// nametable so they need no ROM.
///
/// The geometry is the part that fails silently: an off-by-one in the status
/// bar offset produces a grid that looks entirely plausible and describes the
/// wrong rows, which shows up as a route into a wall rather than as an error.
@Suite("Zelda playfield")
struct PlayfieldTests {
    private final class PlainMapper: Mapper {
        let mirroring = Mirroring.horizontal
        private var chr = [UInt8](repeating: 0, count: 0x2000)
        func cpuRead(_: UInt16) -> UInt8? { nil }
        func cpuWrite(_: UInt16, _: UInt8) {}
        func ppuRead(_ address: UInt16) -> UInt8 { chr[Int(address & 0x1FFF)] }
        func ppuWrite(_ address: UInt16, _ value: UInt8) { chr[Int(address & 0x1FFF)] = value }
    }

    /// Fills the whole playfield with one tile, then lets a test overwrite the
    /// cells it cares about.
    private func ppu(fill: UInt8) -> PPU {
        let p = PPU(mapper: PlainMapper())
        for row in Zelda.Playfield.topTileRow..<30 {
            for column in 0..<32 {
                p.ppuWrite(UInt16(0x2000 + row * 32 + column), fill)
            }
        }
        return p
    }

    private func write(_ p: PPU, cell column: Int, _ row: Int, tiles: [UInt8]) {
        let tileColumn = column * 2
        let tileRow = Zelda.Playfield.topTileRow + row * 2
        p.ppuWrite(UInt16(0x2000 + tileRow * 32 + tileColumn), tiles[0])
        p.ppuWrite(UInt16(0x2000 + tileRow * 32 + tileColumn + 1), tiles[1])
        p.ppuWrite(UInt16(0x2000 + (tileRow + 1) * 32 + tileColumn), tiles[2])
        p.ppuWrite(UInt16(0x2000 + (tileRow + 1) * 32 + tileColumn + 1), tiles[3])
    }

    @Test("The playfield is 16x11 cells below a 64-pixel status bar")
    func geometry() {
        #expect(Zelda.Playfield.columns == 16)
        #expect(Zelda.Playfield.rows == 11)
        #expect(Zelda.Playfield.topPixel == 64)
        // 11 rows of 16 pixels below a 64-pixel bar fills the 240-line screen.
        #expect(Zelda.Playfield.topPixel + Zelda.Playfield.rows * 16 == 240)
    }

    /// Measured on the real game: on overworld screen $77 Link reads
    /// `$0070 = $78`, `$0084 = $8D` and is stood in the middle of the screen,
    /// which is cell (8,5) of 16x11.
    @Test("Link's measured start position maps to the centre cell")
    func linkStartCell() {
        #expect(Zelda.Playfield.column(forLinkX: 0x78) == 8)
        #expect(Zelda.Playfield.row(forLinkY: 0x8D) == 5)
    }

    /// Measured on screen $37: `$0070 = $4A`, `$0084 = $85` is cell (5,4).
    @Test("A second measured position agrees")
    func secondMeasuredPosition() {
        #expect(Zelda.Playfield.column(forLinkX: 0x4A) == 5)
        #expect(Zelda.Playfield.row(forLinkY: 0x85) == 4)
    }

    @Test("The top of the playfield is row 0, not a negative row")
    func topOfPlayfield() {
        #expect(Zelda.Playfield.row(forLinkY: Zelda.Playfield.topPixel - 8) == 0)
    }

    @Test("A cell of dungeon floor is walkable")
    func dungeonFloor() {
        let p = ppu(fill: 0x74)
        write(p, cell: 3, 3, tiles: [0x74, 0x76, 0x75, 0x77])
        #expect(Zelda.Playfield.isWalkable(column: 3, row: 3, ppu: p, table: 0))
    }

    @Test("A cell of wall is not walkable")
    func wall() {
        let p = ppu(fill: 0x74)
        write(p, cell: 3, 3, tiles: [0xDC, 0xDC, 0xDC, 0xD0])
        #expect(Zelda.Playfield.isWalkable(column: 3, row: 3, ppu: p, table: 0) == false)
    }

    /// The rule that decides the whole thing. A dungeon door does not sit on
    /// the metatile grid — measured in room $63, the north passage reads
    /// `79 24 / 7A 77` in one cell and `24 7B / 75 7C` in the next, each half
    /// frame and half floor. All-four would wall every room shut.
    @Test("A doorway that is half frame and half floor is walkable")
    func doorwayIsWalkable() {
        let p = ppu(fill: 0xDC)
        write(p, cell: 7, 1, tiles: [0x79, 0x24, 0x7A, 0x77])
        write(p, cell: 8, 1, tiles: [0x24, 0x7B, 0x75, 0x7C])
        #expect(Zelda.Playfield.isWalkable(column: 7, row: 1, ppu: p, table: 0))
        #expect(Zelda.Playfield.isWalkable(column: 8, row: 1, ppu: p, table: 0))
    }

    /// The other half of the same rule: one floor tile abutting a wall must not
    /// make the wall walkable, or routes clip corners.
    @Test("A wall cell touching one floor tile stays blocked")
    func oneFloorTileIsNotEnough() {
        let p = ppu(fill: 0xDC)
        write(p, cell: 5, 5, tiles: [0x74, 0xDC, 0xDC, 0xDC])
        #expect(Zelda.Playfield.isWalkable(column: 5, row: 5, ppu: p, table: 0) == false)
    }

    @Test("An unknown tile is blocked, so the table degrades rather than lies")
    func unknownTilesAreBlocked() {
        let p = ppu(fill: 0x74)
        write(p, cell: 2, 2, tiles: [0xEE, 0xEF, 0xF0, 0xF1])
        #expect(Zelda.Playfield.isWalkable(column: 2, row: 2, ppu: p, table: 0) == false)
    }

    @Test("The walkability bitmap is row-major and the right size")
    func bitmapShape() {
        let p = ppu(fill: 0x26)
        write(p, cell: 4, 2, tiles: [0xDC, 0xDC, 0xDC, 0xDC])
        let flags = Zelda.Playfield.walkability(ppu: p, table: 0)
        #expect(flags.count == Zelda.Playfield.columns * Zelda.Playfield.rows)
        #expect(flags[2 * Zelda.Playfield.columns + 4] == false)
        #expect(flags[2 * Zelda.Playfield.columns + 5] == true)
    }

    /// The status bar must not leak into the grid. Filling row 7 — the last
    /// status-bar row — with floor must leave every playfield cell unchanged.
    @Test("The status bar is outside the grid")
    func statusBarIsExcluded() {
        let p = ppu(fill: 0xDC)
        for column in 0..<32 {
            p.ppuWrite(UInt16(0x2000 + 7 * 32 + column), 0x74)
        }
        #expect(Zelda.Playfield.walkability(ppu: p, table: 0).allSatisfy { !$0 })
    }
}
