/// A walkable/blocked grid over one screen, and A* across it.
///
/// This is what replaces sweeping coordinates and checking whether the screen
/// number changed. The emulator is already rendering the room, so the geometry
/// is sitting in the nametable; a sweep spends minutes rediscovering by trial
/// what one read of VRAM already knows, and learns nothing reusable when it
/// succeeds.
///
/// Deliberately game-agnostic: it takes a grid of booleans. Deciding which tile
/// indices are floor belongs to the game target.
public struct TileGrid {
    public struct Cell: Hashable, Equatable {
        public let column: Int
        public let row: Int
        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }
    }

    public let columns: Int
    public let rows: Int
    private let walkable: [Bool]

    public init(columns: Int, rows: Int, walkable: [Bool]) {
        precondition(walkable.count == columns * rows, "walkable must be columns * rows")
        self.columns = columns
        self.rows = rows
        self.walkable = walkable
    }

    /// Out-of-bounds reads as blocked rather than trapping: a search that
    /// wanders off the edge should simply find nothing there.
    public func isWalkable(_ cell: Cell) -> Bool {
        guard (0..<columns).contains(cell.column), (0..<rows).contains(cell.row) else {
            return false
        }
        return walkable[cell.row * columns + cell.column]
    }

    private func neighbours(of cell: Cell) -> [Cell] {
        [
            Cell(column: cell.column + 1, row: cell.row),
            Cell(column: cell.column - 1, row: cell.row),
            Cell(column: cell.column, row: cell.row + 1),
            Cell(column: cell.column, row: cell.row - 1),
        ].filter(isWalkable)
    }

    /// Manhattan distance. Admissible because movement is four-way — the d-pad
    /// has no diagonal, and a heuristic that assumed one would overestimate and
    /// stop being optimal.
    private func heuristic(_ a: Cell, _ b: Cell) -> Int {
        abs(a.column - b.column) + abs(a.row - b.row)
    }

    /// Shortest four-way route from `start` to `goal`, inclusive of both, or
    /// nil when there is none.
    ///
    /// Returning nil for a blocked endpoint rather than something approximate
    /// is the whole safety story: the caller falls back to the old sweep, so a
    /// walkability table that is wrong degrades instead of walking Link into a
    /// wall and waiting.
    public func path(from start: Cell, to goal: Cell) -> [Cell]? {
        guard isWalkable(start), isWalkable(goal) else { return nil }
        if start == goal { return [start] }

        var cameFrom: [Cell: Cell] = [:]
        var costSoFar: [Cell: Int] = [start: 0]
        // The grid is 16x11, so a sorted-array frontier beats the bookkeeping of
        // a real priority queue and keeps this readable.
        var frontier: [(cell: Cell, priority: Int)] = [(start, heuristic(start, goal))]

        while !frontier.isEmpty {
            let index = frontier.indices.min { frontier[$0].priority < frontier[$1].priority }!
            let current = frontier.remove(at: index).cell

            if current == goal {
                var route = [current]
                var node = current
                while let previous = cameFrom[node] {
                    route.append(previous)
                    node = previous
                }
                return route.reversed()
            }

            for next in neighbours(of: current) {
                let cost = costSoFar[current]! + 1
                if costSoFar[next] == nil || cost < costSoFar[next]! {
                    costSoFar[next] = cost
                    cameFrom[next] = current
                    frontier.append((next, cost + heuristic(next, goal)))
                }
            }
        }
        return nil
    }

    /// The grid as text, with the route drawn on it.
    ///
    /// A walkability table is wrong in ways that are obvious in a picture and
    /// invisible in a list of coordinates — a doorway classified as wall shows
    /// up instantly as a route going the long way round.
    public func render(path: [Cell] = [], start: Cell? = nil, goal: Cell? = nil) -> String {
        let onPath = Set(path)
        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            for column in 0..<columns {
                let cell = Cell(column: column, row: row)
                if cell == start { line += "S" }
                else if cell == goal { line += "G" }
                else if onPath.contains(cell) { line += "o" }
                else if isWalkable(cell) { line += "." }
                else { line += "#" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Turns a route into the input-script syntax the rest of the harness already
/// speaks, so pathfinder output feeds `play` and `probe` unchanged rather than
/// becoming a second, incompatible way to describe movement.
public enum RouteScript {
    /// Consecutive steps in the same direction collapse into one segment:
    /// `right:48` rather than three `right:16`s. Shorter, and it reads like the
    /// hand-written scripts in `docs/scripts/`.
    public static func script(for path: [TileGrid.Cell], framesPerCell: Int) -> String {
        guard path.count > 1 else { return "" }

        var segments: [(direction: String, cells: Int)] = []
        for (from, to) in zip(path, path.dropFirst()) {
            let direction = if to.column > from.column {
                "right"
            } else if to.column < from.column {
                "left"
            } else if to.row > from.row {
                "down"
            } else {
                "up"
            }

            if segments.last?.direction == direction {
                segments[segments.count - 1].cells += 1
            } else {
                segments.append((direction, 1))
            }
        }
        return segments.map { "\($0.direction):\($0.cells * framesPerCell)" }
            .joined(separator: ",")
    }
}
