import Foundation
import NESCore

/// Reads what is actually on screen out of OAM.
///
/// Route scripts treat a room as static geometry, which is wrong: Zelda's rooms
/// are mostly enemies, and a script that worked once fails on replay because a
/// Keese drifted somewhere else. Blind coordinate sweeps cannot fix that — the
/// harness has to be able to answer "what else is here, and where".
///
/// OAM is the cheap half of that answer. Sprite positions are already in the
/// emulator and need no reverse engineering; which RAM slots hold enemy *type*
/// and *health* is the expensive half, and belongs to the symbol map work.
public enum Entities {
    /// One hardware sprite. OAM stores Y minus one, matching `PPU`.
    public struct Sprite {
        public let x: Int
        public let y: Int
        public let tile: UInt8
        public let attributes: UInt8
    }

    /// A cluster of sprites the game draws as one thing.
    ///
    /// Zelda composes almost every actor from a 2x2 block of 8x8 sprites, so
    /// raw OAM entries are a factor of four away from being useful.
    public struct Entity {
        public let x: Int
        public let y: Int
        public let sprites: [Sprite]

        /// Centre, which is what distance comparisons should use — the corner
        /// of a 16x16 actor is up to 11px from where it actually is.
        public var centre: (x: Int, y: Int) { (x + 8, y + 8) }
    }

    /// Top of Zelda's playfield. The status bar occupies the scanlines above
    /// it and draws its own sprites — hearts, the item icons, the map cursor —
    /// which are not actors and must never become sword targets.
    public static let playfieldTop = 64
    public static let playfieldBottom = 232

    /// Sprites the PPU is actually drawing, restricted to the playfield.
    ///
    /// Three things get excluded, all of which showed up as phantom "actors"
    /// the first time this ran: sprites parked off-screen at Y >= 0xEF, status
    /// bar sprites above the playfield, and sprites parked at X = 0, which is
    /// where Zelda leaves the ones it is not using.
    public static func sprites(in oam: [UInt8]) -> [Sprite] {
        stride(from: 0, to: 256, by: 4).compactMap { base in
            let rawY = Int(oam[base])
            guard rawY < 0xEF else { return nil }
            // OAM stores Y minus one, so the drawn row is one below.
            let y = rawY + 1
            let x = Int(oam[base + 3])
            guard y >= playfieldTop, y < playfieldBottom, x > 0 else { return nil }
            return Sprite(x: x, y: y, tile: oam[base + 1], attributes: oam[base + 2])
        }
    }

    /// Groups sprites into actors by proximity.
    ///
    /// Single-link clustering with a tile-sized radius. Two actors standing
    /// closer than 8px merge into one, which is acceptable: the caller wants
    /// somewhere to swing a sword, and a merged pair is still in the right
    /// direction.
    public static func cluster(_ sprites: [Sprite], radius: Int = 9) -> [Entity] {
        var remaining = sprites
        var entities: [Entity] = []

        while !remaining.isEmpty {
            var group = [remaining.removeFirst()]
            var grew = true
            while grew {
                grew = false
                for (index, candidate) in remaining.enumerated().reversed() {
                    let touches = group.contains { member in
                        abs(member.x - candidate.x) <= radius
                            && abs(member.y - candidate.y) <= radius
                    }
                    if touches {
                        group.append(candidate)
                        remaining.remove(at: index)
                        grew = true
                    }
                }
            }
            let minX = group.map(\.x).min() ?? 0
            let minY = group.map(\.y).min() ?? 0
            entities.append(Entity(x: minX, y: minY, sprites: group))
        }
        return entities
    }

    /// Splits the actors into Link and everything else.
    ///
    /// Link is identified by position rather than by tile index: `$0070`/`$0084`
    /// are known, and matching against them needs no sprite table. Anything
    /// within half a tile of Link's own coordinates is him (or his sword, which
    /// is drawn separately and must not be mistaken for a target).
    /// Items are separated from enemies by sprite count.
    ///
    /// Zelda runs the PPU in 8x16 sprite mode, so an actor is two sprites side
    /// by side and a floor pickup is one. That distinction matters more than it
    /// sounds: the room-clearing loop spent 552 swings and six thousand frames
    /// attacking a dropped key because it counted as an enemy that would not
    /// die. Items are collected by walking onto them, never by swinging.
    public static func classify(
        oam: [UInt8], linkX: Int, linkY: Int
    ) -> (link: Entity?, enemies: [Entity], items: [Entity]) {
        let all = cluster(sprites(in: oam))
        var link: Entity?
        var enemies: [Entity] = []
        var items: [Entity] = []

        for entity in all {
            if abs(entity.x - linkX) <= 12, abs(entity.y - linkY) <= 12 {
                // Keep the closest match; the sword shares Link's neighbourhood.
                if let existing = link {
                    let old = abs(existing.x - linkX) + abs(existing.y - linkY)
                    let new = abs(entity.x - linkX) + abs(entity.y - linkY)
                    if new < old { link = entity }
                } else {
                    link = entity
                }
            } else if entity.sprites.count == 1 {
                items.append(entity)
            } else {
                enemies.append(entity)
            }
        }
        return (link, enemies, items)
    }

    /// One-line summary for `--oam`, so a run can be read without a screenshot.
    public static func report(oam: [UInt8], linkX: Int, linkY: Int) -> String {
        let (link, enemies, items) = classify(oam: oam, linkX: linkX, linkY: linkY)
        var lines = [String(
            format: "  link   x=$%02X y=$%02X  (%@)",
            linkX, linkY, link == nil ? "no sprite" : "\(link!.sprites.count) sprites")]
        if enemies.isEmpty, items.isEmpty {
            lines.append("  (nothing else on screen)")
        }
        func describe(_ label: String, _ list: [Entity]) {
            for (index, entity) in list.enumerated() {
                lines.append(String(
                    format: "  %@ %d  x=$%02X y=$%02X  %d sprites  tiles %@",
                    label, index, entity.x, entity.y, entity.sprites.count,
                    entity.sprites.map { String(format: "%02X", $0.tile) }
                        .joined(separator: " ")))
            }
        }
        describe("enemy", enemies)
        describe("item ", items)
        return lines.joined(separator: "\n")
    }
}
