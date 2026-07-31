import Foundation
import NESCore

/// Breadth-first search over overworld screens, driving the real game.
///
/// Zelda's overworld is a 16x8 grid, and the current screen lives at `$00EB`
/// encoded as `(row << 4) | column`. Terrain blocks most edges, so a route
/// cannot be derived from coordinates alone — but it can be *searched* by
/// actually trying moves from a save state and asking the game where you ended
/// up.
///
/// Single-direction moves are not enough: an exit is often a gap off to one
/// side, so Link has to sidestep before pushing through. The move set therefore
/// includes "sidestep, then go", which is what makes most of the map reachable.
enum Navigator {

    /// Address of the current overworld screen number.
    static let screenAddress: UInt16 = 0x00EB
    /// Health: high nibble is heart containers minus one, low nibble is full
    /// hearts remaining.
    static let healthAddress: UInt16 = 0x066F
    /// Fractional part of the current heart, 0...255.
    static let partialHeartAddress: UInt16 = 0x0670

    /// Refills Link to full.
    ///
    /// Search runs are long and unarmed — Link starts with no sword — so
    /// without this he dies to the first Octorok and the search stalls with
    /// every screen looking like a dead end. This only touches RAM during
    /// automated exploration; the game itself is untouched.
    static func refillHealth(_ nes: NES) {
        let health = nes.cpuRead(healthAddress)
        let containers = health >> 4
        nes.cpuWrite(healthAddress, (containers << 4) | containers)
        nes.cpuWrite(partialHeartAddress, 0xFF)
    }

    /// One button held for a number of frames.
    struct Press {
        let button: NESButton
        let frames: Int
    }

    /// A named sequence of presses tried as a single search edge.
    struct Move {
        let name: String
        let presses: [Press]
    }

    struct Node {
        let screen: UInt8
        let state: SaveState
        let route: [String]
    }

    static func describe(_ screen: UInt8) -> String {
        String(format: "$%02X (col %d, row %d)", screen, screen & 0x0F, screen >> 4)
    }

    /// One straight push and one sweeping push per direction.
    ///
    /// Straight pushes only work when Link happens to be lined up with the
    /// exit. Screen gaps in Zelda are often a single tile wide — measured on
    /// screen $67, moving up 80 frames then left escapes, while 70 or 100 do
    /// not — so blind perpendicular offsets miss almost every time and would
    /// need far too many attempts to cover.
    ///
    /// The sweep instead holds the target direction *while* oscillating
    /// perpendicular, so Link slides along the wall and falls through whatever
    /// gap exists. One move per direction covers every offset.
    static func moves(crossing: Int) -> [Move] {
        let cardinals: [(String, NESButton, NESButton, NESButton)] = [
            ("up",    .up,    .left, .right),
            ("right", .right, .up,   .down),
            ("down",  .down,  .left, .right),
            ("left",  .left,  .up,   .down),
        ]

        var result: [Move] = []
        for (name, forward, perpA, perpB) in cardinals {
            result.append(Move(
                name: name,
                presses: [Press(button: forward, frames: crossing)]))

            // Oscillate perpendicular while continuously pushing forward.
            var sweep: [Press] = []
            for step in 0..<10 {
                let perpendicular = step % 2 == 0 ? perpA : perpB
                sweep.append(Press(button: [forward, perpendicular], frames: 46))
            }
            result.append(Move(name: "\(name)-sweep", presses: sweep))
        }
        return result
    }

    /// Searches for `target`, returning the route and the state on arrival.
    static func search(
        cartridge: Cartridge,
        from start: SaveState,
        to target: UInt8,
        framesPerMove: Int,
        maxScreens: Int,
        verbose: Bool
    ) -> Node? {

        let moveSet = moves(crossing: framesPerMove)
        let nes = try! NES(cartridge: cartridge)
        try? nes.restoreState(start)
        let startScreen = nes.cpuRead(screenAddress)

        if startScreen == target {
            return Node(screen: startScreen, state: start, route: [])
        }

        var visited: Set<UInt8> = [startScreen]
        var queue = [Node(screen: startScreen, state: start, route: [])]
        var explored = 0

        while !queue.isEmpty && explored < maxScreens {
            let node = queue.removeFirst()
            explored += 1

            if verbose {
                print("  exploring \(describe(node.screen))  "
                    + "depth \(node.route.count), \(visited.count) seen")
            }

            for move in moveSet {
                try? nes.restoreState(node.state)

                for press in move.presses {
                    nes.controller1.releaseAll()
                    nes.controller1.press(press.button)
                    for frame in 0..<press.frames {
                        // Top up regularly: a single refill at the start is not
                        // enough to survive a long push past several enemies.
                        if frame % 30 == 0 { refillHealth(nes) }
                        nes.stepFrame()
                    }
                }
                nes.controller1.releaseAll()
                // Let the scroll transition settle before reading the screen.
                for _ in 0..<24 { nes.stepFrame() }

                let reached = nes.cpuRead(screenAddress)
                guard reached != node.screen, !visited.contains(reached) else { continue }

                visited.insert(reached)
                let next = Node(
                    screen: reached,
                    state: nes.captureState(),
                    route: node.route + ["\(move.name) -> \(describe(reached))"])

                if verbose {
                    print("    \(move.name) reaches \(describe(reached))")
                }
                if reached == target { return next }
                queue.append(next)
            }
        }
        return nil
    }
}
