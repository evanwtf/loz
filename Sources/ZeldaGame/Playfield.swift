import NESCore

/// The playfield: where the game is actually played, and which of its cells
/// Link can stand on.
///
/// Everything here is cartridge-specific — the geometry, the tile indices, the
/// fact that there is a status bar at all — so it lives in the game target.
///
/// Deliberately no pathfinder. A* and the input-script emitter are harness
/// concerns and live in `NESAnalysis`, which this target must never depend on;
/// the caller reads the facts here and builds the grid. That split is why the
/// shipping app carries the room geometry it might one day draw from, and not a
/// search algorithm it will never run.
public extension Zelda {
    enum Playfield {
        /// The playfield is 16x11 cells of 16x16 pixels, below the status bar.
        ///
        /// The NES screen is 32x30 tiles of 8x8. Zelda spends the top 8 tile
        /// rows on the status bar and lays the room out below in 16x16
        /// metatiles, which is why a room is 16x11 and not 32x22: the four
        /// tiles of a metatile are always the same kind of thing.
        public static let columns = 16
        public static let rows = 11

        /// Side of one cell, in pixels.
        public static let cellSize = 16

        /// First nametable tile row of the playfield. The status bar is 64
        /// pixels — eight rows of 8x8 tiles.
        public static let topTileRow = 8

        /// Pixel Y of the top of the playfield, for converting Link's position.
        public static var topPixel: Int { topTileRow * 8 }

        /// Tile indices Link can stand on.
        ///
        /// Built by observation rather than copied from a published map:
        /// `nesrun tiles --census` replays a route and reports which tiles Link
        /// actually occupied, and this is what came back across the committed
        /// route chain. Anything not listed is treated as blocked, so an
        /// unknown tile costs a longer route or a fallback to the old sweep —
        /// never a walk into a wall.
        ///
        /// Known incomplete, and deliberately so — see `isWalkable`.
        public static let walkableTiles: Set<UInt8> = [
            0x24,                          // blank — doorway interiors, cave mouths
            0x26,                          // overworld ground
            0x74, 0x75, 0x76, 0x77,        // dungeon floor, all four tiles of the metatile
            0x90, 0x95,                    // the bridge over the water on screen $38
        ]

        /// Which cell column a pixel X falls in.
        ///
        /// Link's RAM position is the top-left of his 16x16 sprite, so his
        /// centre is offset by 8. Using the centre matters: on the origin
        /// alone, a Link straddling two cells reports the one he is leaving.
        public static func column(forLinkX x: Int) -> Int { (x + 8) / cellSize }

        /// Which cell row a pixel Y falls in.
        public static func row(forLinkY y: Int) -> Int { (y + 8 - topPixel) / cellSize }

        /// The four nametable tile indices making up one cell, in reading order.
        public static func tiles(
            column: Int, row: Int, ppu: PPU, table: Int
        ) -> [UInt8] {
            let tileColumn = column * 2
            let tileRow = topTileRow + row * 2
            return [
                ppu.nametableTile(column: tileColumn, row: tileRow, table: table),
                ppu.nametableTile(column: tileColumn + 1, row: tileRow, table: table),
                ppu.nametableTile(column: tileColumn, row: tileRow + 1, table: table),
                ppu.nametableTile(column: tileColumn + 1, row: tileRow + 1, table: table),
            ]
        }

        /// Whether a cell can be walked on.
        ///
        /// A cell counts as walkable when at least half its tiles are, which is
        /// neither of the two obvious rules and is chosen because of doorways.
        /// A dungeon door does not sit on the metatile grid: its passage
        /// straddles two cells, each half door frame and half open floor.
        /// Requiring all four tiles would classify every door as wall and no
        /// route would ever leave a room; accepting any single tile would let a
        /// route clip the corner of a wall that happens to abut floor.
        ///
        /// **This is approximate, and the approximation is bounded on purpose.**
        /// The game does not decide collisions from the cell under Link's
        /// centre — it uses a box around his feet — so a census that anchors on
        /// the centre inherits that error and reports him occasionally
        /// "standing on" a cell he is only leaning into. Rather than widen the
        /// tile set on that evidence, unrecognised tiles stay blocked, which
        /// costs a longer route or an honest "no route" and never a walk into a
        /// wall. `nesrun navigate` falls back to its coordinate sweep when this
        /// returns nothing.
        public static func isWalkable(
            column: Int, row: Int, ppu: PPU, table: Int
        ) -> Bool {
            let open = tiles(column: column, row: row, ppu: ppu, table: table)
                .count { walkableTiles.contains($0) }
            return open >= 2
        }

        /// The whole playfield as a row-major walkability bitmap, ready to be
        /// handed to a grid search.
        public static func walkability(ppu: PPU, table: Int? = nil) -> [Bool] {
            let table = table ?? ppu.activeNametable
            var flags: [Bool] = []
            flags.reserveCapacity(columns * rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    flags.append(isWalkable(column: column, row: row, ppu: ppu, table: table))
                }
            }
            return flags
        }
    }
}
