@testable import NESAnalysis
import Testing

/// Reading actors out of OAM looks trivial and is not: every one of these cases
/// is a mistake the harness actually made, and each one cost a wrong conclusion
/// about what was on screen rather than an obvious failure.
@Suite("OAM entity reading")
struct EntitiesTests {
    /// Builds an OAM table with every sprite parked off-screen, then places the
    /// given ones. Matches the hardware layout: Y-1, tile, attributes, X.
    private func oam(_ sprites: [(x: Int, y: Int, tile: UInt8)]) -> [UInt8] {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, sprite) in sprites.enumerated() {
            let base = index * 4
            table[base] = UInt8(sprite.y - 1)          // OAM stores Y minus one
            table[base + 1] = sprite.tile
            table[base + 2] = 0
            table[base + 3] = UInt8(sprite.x)
        }
        return table
    }

    @Test("OAM's Y-minus-one is undone, so positions match the screen")
    func decodesYOffset() {
        let sprites = Entities.sprites(in: oam([(x: 100, y: 120, tile: 0x9A)]))
        #expect(sprites.count == 1)
        #expect(sprites[0].y == 120)
        #expect(sprites[0].x == 100)
    }

    @Test("Sprites parked off-screen are not actors")
    func ignoresParkedSprites() {
        // 0xFF fill means Y = 0xFF, the standard park position.
        #expect(Entities.sprites(in: [UInt8](repeating: 0xFF, count: 256)).isEmpty)
    }

    /// The status bar draws hearts and item icons as sprites. Treating them as
    /// actors put four phantom targets on every screen the first time this ran.
    @Test("Status bar sprites above the playfield are excluded")
    func ignoresStatusBar() {
        let table = oam([
            (x: 100, y: 40, tile: 0x3E),    // in the status bar
            (x: 100, y: 120, tile: 0x9A),   // in the playfield
        ])
        let sprites = Entities.sprites(in: table)
        #expect(sprites.count == 1)
        #expect(sprites[0].y == 120)
    }

    @Test("Sprites parked at x = 0 are excluded")
    func ignoresLeftEdgeParking() {
        #expect(Entities.sprites(in: oam([(x: 0, y: 120, tile: 0x1C)])).isEmpty)
    }

    /// Zelda runs the PPU in 8x16 sprite mode, so one actor is two sprites.
    @Test("Adjacent sprites cluster into one actor")
    func clustersAdjacentSprites() {
        let table = oam([
            (x: 100, y: 120, tile: 0x9A),
            (x: 108, y: 120, tile: 0x9A),
        ])
        let entities = Entities.cluster(Entities.sprites(in: table))
        #expect(entities.count == 1)
        #expect(entities[0].sprites.count == 2)
    }

    @Test("Distant sprites stay separate actors")
    func keepsDistantSpritesApart() {
        let table = oam([
            (x: 40, y: 120, tile: 0x9A),
            (x: 41, y: 120, tile: 0x9A),
            (x: 180, y: 120, tile: 0x9C),
            (x: 188, y: 120, tile: 0x9C),
        ])
        #expect(Entities.cluster(Entities.sprites(in: table)).count == 2)
    }

    @Test("The actor standing where Link is, is Link")
    func identifiesLink() {
        let table = oam([
            (x: 100, y: 120, tile: 0x60),
            (x: 108, y: 120, tile: 0x60),
        ])
        let result = Entities.classify(oam: table, linkX: 100, linkY: 120)
        #expect(result.link != nil)
        #expect(result.enemies.isEmpty)
    }

    /// The one that mattered most: a dropped key counted as an enemy, so the
    /// room-clearing loop spent 552 swings and 6000 frames attacking an item it
    /// only had to walk onto.
    @Test("A single sprite is an item, a pair is an enemy")
    func separatesItemsFromEnemies() {
        let table = oam([
            (x: 100, y: 120, tile: 0x60),   // Link
            (x: 108, y: 120, tile: 0x60),
            (x: 60, y: 180, tile: 0x9A),    // enemy: two sprites
            (x: 68, y: 180, tile: 0x9A),
            (x: 164, y: 193, tile: 0x2E),   // key: one sprite
        ])
        let result = Entities.classify(oam: table, linkX: 100, linkY: 120)
        #expect(result.enemies.count == 1)
        #expect(result.items.count == 1)
        #expect(result.items[0].sprites[0].tile == 0x2E)
    }

    @Test("An empty room reports nothing but Link")
    func reportsEmptyRoom() {
        let table = oam([
            (x: 100, y: 120, tile: 0x60),
            (x: 108, y: 120, tile: 0x60),
        ])
        let result = Entities.classify(oam: table, linkX: 100, linkY: 120)
        #expect(result.enemies.isEmpty)
        #expect(result.items.isEmpty)
    }

    /// Distance comparisons must use the centre: the corner of a 16x16 actor is
    /// up to 11px from where it actually is, which is most of a sword's reach.
    @Test("An entity's centre is offset from its corner")
    func centreIsOffsetFromCorner() {
        let table = oam([
            (x: 100, y: 120, tile: 0x9A),
            (x: 108, y: 120, tile: 0x9A),
        ])
        let entity = Entities.cluster(Entities.sprites(in: table))[0]
        #expect(entity.x == 100)
        #expect(entity.centre.x == 108)
        #expect(entity.centre.y == 128)
    }
}
