import Foundation
import NESAnalysis
import NESCore

/// Fights whatever is in the current room until it is empty.
///
/// This is the first closed-loop driver in the harness. Everything else replays
/// a fixed script and hopes; that works for walking across static geometry and
/// fails immediately in combat, because enemies move. Standing in a corner
/// swinging killed one Keese and then waited out ninety swings while the other
/// two drifted to the far wall — a fixed script has no way to notice that.
///
/// The loop is deliberately simple: every few frames, look at OAM, walk at the
/// nearest actor, and swing when close enough. It does not need to be a good
/// player, only a reliable one.
enum ClearRoom {
    struct Outcome {
        var cleared = false
        var died = false
        var frames = 0
        var swings = 0
        var pickups = 0
        var remaining = 0
    }

    /// Frames per decision. Long enough that Link commits to a direction and
    /// actually covers ground, short enough to react to a Keese changing course.
    static let tickFrames = 8

    /// Reach of a sword swing, in pixels, plus a margin. Zelda's melee range is
    /// about a tile; being slightly generous costs a wasted swing, being
    /// slightly mean costs a hit taken while walking in.
    static let strikeRange = 20

    /// Consecutive empty observations before the room counts as cleared.
    ///
    /// One is not enough. A dying enemy stops drawing for a few frames before
    /// its replacement appears, so a single empty read reported "CLEARED, 0
    /// actors left" for a room that still had a Keese in it.
    static let clearConfirmTicks = 6

    /// Frames per decision while walking onto a pickup. Shorter than a combat
    /// tick because overshooting an item by half a tile means orbiting it.
    static let itemTickFrames = 3

    /// Nearest actor by Manhattan distance between centres. Cheap, and because
    /// movement is axis-aligned it predicts travel time better than Euclidean.
    ///
    /// Written out rather than inlined as a closure: as a one-liner inside
    /// `min(by:)` the type checker gave up on it entirely.
    private static func nearest(
        to linkX: Int, _ linkY: Int, among entities: [Entities.Entity]
    ) -> Entities.Entity? {
        var best: Entities.Entity?
        var bestDistance = Int.max
        for entity in entities {
            let dx: Int = abs(entity.centre.x - (linkX + 8))
            let dy: Int = abs(entity.centre.y - (linkY + 8))
            let distance: Int = dx + dy
            if distance < bestDistance {
                bestDistance = distance
                best = entity
            }
        }
        return best
    }

    static func run(
        nes: NES,
        maxFrames: Int = 3600,
        verbose: Bool = false
    ) -> Outcome {
        var outcome = Outcome()
        var emptyTicks = 0

        while outcome.frames < maxFrames {
            let linkX = Int(nes.cpuRead(0x0070))
            let linkY = Int(nes.cpuRead(0x0084))
            let (_, enemies, items) = Entities.classify(
                oam: nes.ppu.oam, linkX: linkX, linkY: linkY)

            // Health reaching zero means the game-over menu, where these inputs
            // mean something entirely different. Stop rather than flail at it.
            if nes.cpuRead(0x066F) & 0x0F == 0, nes.cpuRead(0x0670) == 0 {
                outcome.died = true
                outcome.remaining = enemies.count
                return outcome
            }

            if enemies.isEmpty {
                // Collect anything the fight dropped before declaring victory:
                // a key on the floor is the whole point of clearing the room.
                if let item = nearest(to: linkX, linkY, among: items) {
                    emptyTicks = 0
                    outcome.pickups += 1
                    let dx = item.centre.x - (linkX + 8)
                    let dy = item.centre.y - (linkY + 8)
                    let towards: NESButton =
                        abs(dx) > abs(dy)
                            ? (dx > 0 ? .right : .left)
                            : (dy > 0 ? .down : .up)
                    if verbose {
                        print(String(
                            format: "  f%-5d link ($%02X,$%02X)  item at (%d,%d) d=(%+d,%+d) collect",
                            outcome.frames, linkX, linkY,
                            item.centre.x, item.centre.y, dx, dy))
                    }
                    nes.controller1.releaseAll()
                    nes.controller1.press(towards)
                    // Shorter ticks than combat: overshooting a pickup by half a
                    // tile means orbiting it instead of standing on it.
                    for _ in 0..<itemTickFrames {
                        nes.stepFrame()
                        outcome.frames += 1
                    }
                    nes.controller1.releaseAll()
                    continue
                }

                emptyTicks += 1
                if emptyTicks >= clearConfirmTicks {
                    outcome.cleared = true
                    return outcome
                }
                nes.controller1.releaseAll()
                for _ in 0..<tickFrames {
                    nes.stepFrame()
                    outcome.frames += 1
                }
                continue
            }
            emptyTicks = 0

            guard let target = nearest(to: linkX, linkY, among: enemies) else { continue }

            let dx = target.centre.x - (linkX + 8)
            let dy = target.centre.y - (linkY + 8)

            // Face the target along its dominant axis. Attacking without first
            // facing the right way is how a swing misses something adjacent.
            let facing: NESButton =
                abs(dx) > abs(dy)
                    ? (dx > 0 ? .right : .left)
                    : (dy > 0 ? .down : .up)

            var buttons = facing
            let inRange = abs(dx) <= strikeRange && abs(dy) <= strikeRange
            if inRange {
                buttons.insert(.a)
                outcome.swings += 1
            }

            if verbose {
                print(String(
                    format: "  f%-5d link ($%02X,$%02X)  %d actors  target (%d,%d) d=(%+d,%+d) %@",
                    outcome.frames, linkX, linkY, enemies.count,
                    target.centre.x, target.centre.y, dx, dy,
                    inRange ? "SWING" : "walk"))
            }

            nes.controller1.releaseAll()
            nes.controller1.press(buttons)
            for _ in 0..<tickFrames {
                nes.stepFrame()
                outcome.frames += 1
            }
            // Release between ticks so the A press is an edge, not a hold —
            // Zelda only starts a swing on a fresh press.
            nes.controller1.releaseAll()
            nes.stepFrame()
            outcome.frames += 1
        }

        let linkX = Int(nes.cpuRead(0x0070))
        let linkY = Int(nes.cpuRead(0x0084))
        outcome.remaining = Entities.classify(
            oam: nes.ppu.oam, linkX: linkX, linkY: linkY).enemies.count
        return outcome
    }
}
