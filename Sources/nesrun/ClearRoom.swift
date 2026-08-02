import Foundation
import NESAnalysis
import NESCore
import ZeldaGame

/// Fights whatever is in the current room until it is empty.
///
/// This is the first closed-loop driver in the harness. Everything else replays
/// a fixed script and hopes; that works for walking across static geometry and
/// fails immediately in combat, because enemies move. Standing in a corner
/// swinging killed one Keese and then waited out ninety swings while the other
/// two drifted to the far wall — a fixed script has no way to notice that.
///
/// The loop is deliberately simple: every few frames, walk at the nearest
/// actor, and swing when close enough. It does not need to be a good player,
/// only a reliable one.
///
/// It reads two different sources for two different questions, which is the
/// point rather than an accident:
///
/// - **How many enemies are left** comes from the slot table at `$0350`. OAM
///   undercounts — room `$63` drew two Stalfos while three were live, and the
///   third simply had not been rendered yet.
/// - **Where to swing** comes from OAM, because the slot table carries type
///   and not position. An enemy the game knows about but has not drawn cannot
///   be aimed at, so the loop waits a tick for it to appear.
enum ClearRoom {
    struct Outcome {
        var cleared = false
        var died = false
        var hitsTaken = 0
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

    /// Ticks to keep waiting for enemies to appear before an empty slot table
    /// is allowed to mean the room was always empty.
    ///
    /// Reading the slot table rather than OAM introduces this hazard, so it is
    /// handled explicitly instead of being left to luck: entering Level 1 room
    /// `$72`, the table reads all zero for about 24 frames — three ticks — and
    /// only then are the three Keese committed to slots. Six ticks is double
    /// the measured delay, and a room that really is empty still terminates
    /// once the window closes.
    static let spawnGraceTicks = 6

    /// Frames per decision while walking onto a pickup. Shorter than a combat
    /// tick because overshooting an item by half a tile means orbiting it.
    static let itemTickFrames = 3

    /// Ticks spent backing away after taking a hit.
    ///
    /// Walking straight back in trades hits one for one, which Link loses: he
    /// has three hearts and a wooden sword, and a Stalfos does not care. Backing
    /// off spends the invulnerability window moving instead of trading, which is
    /// the difference between clearing a room and dying in it.
    static let retreatTicks = 4

    /// Link's health as one comparable number, so "did that hurt" is a single
    /// test rather than two.
    ///
    /// `$066F` low nibble is whole hearts remaining and `$0670` is the fraction
    /// of the current one. Both zero means dead — confirmed against the death
    /// animation, which reads exactly `$066F = $20`, `$0670 = $00`.
    static func health(_ nes: NES) -> Int {
        Int(nes.cpuRead(0x066F) & 0x0F) * 256 + Int(nes.cpuRead(0x0670))
    }

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

    /// The opposite of a facing direction.
    private static func away(from facing: NESButton) -> NESButton {
        switch facing {
        case .left: .right
        case .right: .left
        case .up: .down
        default: .up
        }
    }

    static func run(
        nes: NES,
        maxFrames: Int = 3600,
        verbose: Bool = false
    ) -> Outcome {
        var outcome = Outcome()
        var monitor = RoomClearMonitor(
            confirmTicks: clearConfirmTicks, spawnGraceTicks: spawnGraceTicks)
        var retreating = 0
        var lastHealth = health(nes)

        while outcome.frames < maxFrames {
            let linkX = Int(nes.cpuRead(0x0070))
            let linkY = Int(nes.cpuRead(0x0084))
            let (_, enemies, items) = Entities.classify(
                oam: nes.ppu.oam, linkX: linkX, linkY: linkY)

            // The authoritative count. `enemies` above is only ever used to
            // decide where to swing.
            let liveEnemies = Zelda.liveEnemyCount(in: nes)

            // Health reaching zero means the death animation and then the
            // game-over menu, where these inputs mean something entirely
            // different. Stop rather than flail at it.
            let currentHealth = health(nes)
            if currentHealth == 0 {
                outcome.died = true
                outcome.remaining = liveEnemies
                return outcome
            }
            if currentHealth < lastHealth {
                outcome.hitsTaken += 1
                retreating = retreatTicks
            }
            lastHealth = currentHealth

            if liveEnemies == 0 {
                // Collect anything the fight dropped before declaring victory:
                // a key on the floor is the whole point of clearing the room.
                // Deliberately not an observation — walking to a key must not
                // count towards the room being confirmed clear, or the loop
                // returns while the key is still on the floor.
                if let item = nearest(to: linkX, linkY, among: items) {
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

                if monitor.observe(liveEnemies: 0) {
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
            monitor.observe(liveEnemies: liveEnemies)

            // The game has enemies in slots that it has not drawn yet, so there
            // is nothing to aim at. Step a tick and look again — returning
            // straight to the top without advancing time would spin forever,
            // which is exactly what this loop did the first time the count
            // stopped coming from OAM.
            guard let target = nearest(to: linkX, linkY, among: enemies) else {
                if verbose {
                    print(String(
                        format: "  f%-5d %d live, none drawn yet — waiting",
                        outcome.frames, liveEnemies))
                }
                nes.controller1.releaseAll()
                for _ in 0..<tickFrames {
                    nes.stepFrame()
                    outcome.frames += 1
                }
                continue
            }

            let dx = target.centre.x - (linkX + 8)
            let dy = target.centre.y - (linkY + 8)

            // Face the target along its dominant axis. Attacking without first
            // facing the right way is how a swing misses something adjacent.
            let facing: NESButton =
                abs(dx) > abs(dy)
                    ? (dx > 0 ? .right : .left)
                    : (dy > 0 ? .down : .up)

            // Just been hit: spend the invulnerability window opening distance
            // rather than trading blows.
            var buttons = facing
            var action = "walk"
            if retreating > 0 {
                retreating -= 1
                buttons = away(from: facing)
                action = "retreat"
            } else if abs(dx) <= strikeRange, abs(dy) <= strikeRange {
                buttons.insert(.a)
                outcome.swings += 1
                action = "SWING"
            }

            if verbose {
                print(String(
                    format: "  f%-5d link ($%02X,$%02X)  hp %3d  %d live/%d drawn  d=(%+d,%+d) %@",
                    outcome.frames, linkX, linkY, currentHealth, liveEnemies,
                    enemies.count, dx, dy, action))
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

        outcome.remaining = Zelda.liveEnemyCount(in: nes)
        return outcome
    }
}
