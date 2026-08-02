import Foundation
import NESAnalysis
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

    /// Frames to hold a direction per 16-pixel cell.
    ///
    /// Measured from the committed routes: `right:260` crosses a 256-pixel
    /// screen, so Link covers roughly a pixel a frame once he is moving.
    static let tileFramesPerCell = 16
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

    /// Moves derived from the room's actual geometry, one per direction.
    ///
    /// For each edge, A* routes from Link to the nearest walkable cell on that
    /// edge and the result is emitted as presses. Where the walkability table
    /// is confident this replaces a blind sweep with a route that is right the
    /// first time.
    ///
    /// **These are additions, not replacements.** They are tried first and the
    /// sweeps stay behind them, so a walkability table that is wrong or simply
    /// does not know a tile costs an extra attempt and nothing else. A grid
    /// that says "no route" produces no move here at all and the search
    /// proceeds exactly as it did before — degrading rather than deadlocking is
    /// the whole reason the old moves are still in the list.
    static func tileAwareMoves(nes: NES, framesPerCell: Int) -> [Move] {
        let grid = Tiles.grid(nes: nes)
        let start = Tiles.linkCell(nes: nes)
        guard grid.isWalkable(start) else { return [] }

        // One step beyond the edge cell is off-screen, which is what actually
        // triggers the transition, so each route ends with a nudge outward.
        let edges: [(name: String, cells: [TileGrid.Cell], push: NESButton)] = [
            ("up", (0..<grid.columns).map { TileGrid.Cell(column: $0, row: 0) }, .up),
            ("down", (0..<grid.columns).map {
                TileGrid.Cell(column: $0, row: grid.rows - 1)
            }, .down),
            ("left", (0..<grid.rows).map { TileGrid.Cell(column: 0, row: $0) }, .left),
            ("right", (0..<grid.rows).map {
                TileGrid.Cell(column: grid.columns - 1, row: $0)
            }, .right),
        ]

        var result: [Move] = []
        for edge in edges {
            let routes = edge.cells.compactMap { grid.path(from: start, to: $0) }
            guard let shortest = routes.min(by: { $0.count < $1.count }) else { continue }

            var presses = pressesFor(path: shortest, framesPerCell: framesPerCell)
            presses.append(Press(button: edge.push, frames: framesPerCell * 2))
            result.append(Move(name: "\(edge.name)-tiles", presses: presses))
        }
        return result
    }

    /// Turns a grid route into presses, collapsing runs the same way
    /// `RouteScript` does for the text form.
    private static func pressesFor(
        path: [TileGrid.Cell], framesPerCell: Int
    ) -> [Press] {
        var presses: [Press] = []
        for (from, to) in zip(path, path.dropFirst()) {
            let button: NESButton = if to.column > from.column {
                .right
            } else if to.column < from.column {
                .left
            } else if to.row > from.row {
                .down
            } else {
                .up
            }

            if let last = presses.last, last.button == button {
                presses[presses.count - 1] = Press(
                    button: button, frames: last.frames + framesPerCell)
            } else {
                presses.append(Press(button: button, frames: framesPerCell))
            }
        }
        return presses
    }

    /// Searches for `target`, returning the route and the state on arrival.
    static func search(
        cartridge: Cartridge,
        from start: SaveState,
        to target: UInt8,
        framesPerMove: Int,
        maxScreens: Int,
        verbose: Bool,
        tileAware: Bool = true
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

        while !queue.isEmpty, explored < maxScreens {
            let node = queue.removeFirst()
            explored += 1

            if verbose {
                print("  exploring \(describe(node.screen))  "
                    + "depth \(node.route.count), \(visited.count) seen")
            }

            // Tile-aware routes are computed per screen — they depend on the
            // room in front of Link, not on the search — and go first so a
            // known-good route is tried before any blind sweep.
            try? nes.restoreState(node.state)
            for _ in 0..<8 { nes.stepFrame() }
            let screenMoves = (tileAware
                ? tileAwareMoves(nes: nes, framesPerCell: tileFramesPerCell)
                : []) + moveSet

            for move in screenMoves {
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
