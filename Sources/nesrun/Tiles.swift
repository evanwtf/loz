import Foundation
import NESAnalysis
import NESCore
import ZeldaGame

/// Reading the room out of the nametable, and routing across it.
///
/// The emulator is already rendering the room, so its geometry is sitting in
/// VRAM. Before this, every dungeon room was solved by sweeping coordinates and
/// checking whether `$00EB` changed — minutes per room, and nothing reusable
/// when it worked.
enum Tiles {
    /// Builds the walkable grid for the current screen.
    ///
    /// The wiring lives here rather than in `ZeldaGame` because the grid search
    /// is in `NESAnalysis`, which no shipping target may depend on. The game
    /// target supplies the facts; the harness supplies the algorithm.
    static func grid(nes: NES, table: Int? = nil) -> TileGrid {
        TileGrid(
            columns: Zelda.Playfield.columns,
            rows: Zelda.Playfield.rows,
            walkable: Zelda.Playfield.walkability(ppu: nes.ppu, table: table))
    }

    /// Where Link is, as a grid cell.
    static func linkCell(nes: NES) -> TileGrid.Cell {
        TileGrid.Cell(
            column: Zelda.Playfield.column(forLinkX: Int(nes.cpuRead(0x0070))),
            row: Zelda.Playfield.row(forLinkY: Int(nes.cpuRead(0x0084))))
    }

    /// The full 32x30 nametable as hex.
    ///
    /// The raw instrument: before a walkable grid can be trusted, the tile
    /// indices it is built from have to be read against a screenshot of the
    /// same moment.
    static func rawDump(nes: NES, table: Int) -> String {
        var lines = ["nametable \(table)  (mirroring \(nes.mapperMirroringName))"]
        lines.append("      " + (0..<32).map { String(format: "%02X", $0) }.joined(separator: " "))
        for row in 0..<30 {
            let cells = (0..<32).map {
                String(format: "%02X", nes.ppu.nametableTile(column: $0, row: row, table: table))
            }
            lines.append(String(format: "  %02d  ", row) + cells.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// Which tiles Link actually stood on over a run.
    ///
    /// This is how `Zelda.Playfield.walkableTiles` was built, and how it should
    /// be extended: replay a route that is known to work and report the tiles
    /// under Link, because a tile he occupied is walkable by definition. It
    /// beats reasoning about what a tile looks like — `$24` is blank space in
    /// the status bar and an open doorway in a dungeon, and only one of those
    /// is something to conclude from.
    struct Census {
        var counts: [UInt8: Int] = [:]
        var samples = 0
        var offPlayfield = 0
        var inTransition = 0

        private var lastScreen: UInt8?
        private var settledFor = 0

        /// Frames a screen must have been stable before its tiles mean
        /// anything.
        ///
        /// Mid-scroll, Link's coordinates and the nametable describe different
        /// screens and the PPU is rendering across both, so sampling then
        /// reports Link standing on trees and dungeon walls — the first census
        /// had `$D8`, a tree, under him 143 times.
        ///
        /// Ninety-six rather than something smaller because `$00EB` changes
        /// *during* the scroll, not after it: the screen number is already the
        /// new one while the old screen is still on display. That is the same
        /// fact the committed routes encode as `wait:90` after every screen
        /// change, and at 40 frames this census was still attributing the
        /// bridge on `$38` to `$37`.
        static let settleFrames = 96

        mutating func sample(nes: NES) {
            let screen = nes.cpuRead(Navigator.screenAddress)
            if screen == lastScreen { settledFor += 1 } else { settledFor = 0 }
            lastScreen = screen
            guard settledFor >= Self.settleFrames else {
                inTransition += 1
                return
            }

            let cell = linkCell(nes: nes)
            guard (0..<Zelda.Playfield.columns).contains(cell.column),
                  (0..<Zelda.Playfield.rows).contains(cell.row)
            else {
                offPlayfield += 1
                return
            }
            samples += 1
            let tiles = Zelda.Playfield.tiles(
                column: cell.column, row: cell.row,
                ppu: nes.ppu, table: nes.ppu.activeNametable)
            for tile in tiles { counts[tile, default: 0] += 1 }

            // Where an unclassified tile turned up, so it can be gone and
            // looked at rather than guessed about.
            if !tiles.allSatisfy({ Zelda.Playfield.walkableTiles.contains($0) }) {
                let key = String(
                    format: "screen $%02X cell (%d,%d): %@",
                    screen, cell.column, cell.row,
                    tiles.map { String(format: "%02X", $0) }.joined(separator: " "))
                sightings[key, default: 0] += 1
            }
        }

        var sightings: [String: Int] = [:]

        var report: String {
            var lines = [
                "\(samples) samples on the playfield, \(offPlayfield) off it, "
                    + "\(inTransition) skipped mid-transition",
            ]
            lines.append("  tile  times under Link  currently classified")
            for (tile, count) in counts.sorted(by: { $0.value > $1.value }) {
                let known = Zelda.Playfield.walkableTiles.contains(tile) ? "walkable" : "BLOCKED"
                lines.append(String(format: "  $%02X   %6d             %@", tile, count, known))
            }
            if !sightings.isEmpty {
                lines.append("")
                lines.append("cells Link occupied that are not all-walkable:")
                for (where_, count) in sightings.sorted(by: { $0.value > $1.value }).prefix(12) {
                    lines.append("  \(count)x  \(where_)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}

extension NES {
    /// Mirroring as a word, for a dump header. The scheme decides which half of
    /// VRAM a nametable read lands in, so a dump that does not say which one is
    /// in force is not reproducible.
    var mapperMirroringName: String {
        switch mapper.mirroring {
        case .horizontal: "horizontal"
        case .vertical: "vertical"
        case .singleScreenLow: "single-screen low"
        case .singleScreenHigh: "single-screen high"
        case .fourScreen: "four-screen"
        }
    }
}
