@testable import NESAnalysis
import Testing

/// A* over a walkable grid, and turning the result back into an input script.
/// Both halves are pure, so they are tested against hand-drawn maps rather than
/// against the game — a pathfinder that cannot cross a corridor in a test will
/// not cross one in a dungeon either.
@Suite("Tile grid pathfinding")
struct TileGridTests {
    /// Builds a grid from ASCII art: `.` walkable, `#` blocked. Reading the map
    /// in the test is the point — a route is much easier to check by eye than
    /// as a list of coordinates.
    private func grid(_ rows: [String]) -> TileGrid {
        TileGrid(
            columns: rows[0].count,
            rows: rows.count,
            walkable: rows.flatMap { $0.map { $0 != "#" } })
    }

    private func cell(_ column: Int, _ row: Int) -> TileGrid.Cell {
        TileGrid.Cell(column: column, row: row)
    }

    @Test("A clear run east is a straight line")
    func straightLine() {
        let g = grid(["....."])
        let path = g.path(from: cell(0, 0), to: cell(4, 0))
        #expect(path?.count == 5)
        #expect(path?.last == cell(4, 0))
    }

    @Test("Start and goal being the same is a path of one, not nil")
    func degeneratePath() {
        let g = grid(["..."])
        #expect(g.path(from: cell(1, 0), to: cell(1, 0)) == [cell(1, 0)])
    }

    /// The shortest route around a wall, not through it.
    @Test("A wall is routed around")
    func routesAroundAWall() {
        let g = grid([
            ".....",
            "###..",
            ".....",
        ])
        let path = g.path(from: cell(0, 0), to: cell(0, 2))
        #expect(path != nil)
        for step in path ?? [] { #expect(g.isWalkable(step)) }
        // East to the gap at column 3, down two, then back west: 9 cells.
        #expect(path?.count == 9)
        #expect(path?.first == cell(0, 0))
        #expect(path?.last == cell(0, 2))
    }

    @Test("A goal walled off completely has no route")
    func noRoute() {
        let g = grid([
            "..#..",
            "..#..",
            "..#..",
        ])
        #expect(g.path(from: cell(0, 0), to: cell(4, 0)) == nil)
    }

    /// Degrading rather than deadlocking matters more than being clever: a
    /// wrong walkability table must produce "no route" for the caller to fall
    /// back on, never a route through a wall.
    @Test("A blocked start or goal has no route")
    func blockedEndpoints() {
        let g = grid(["#..", "...", "..#"])
        #expect(g.path(from: cell(0, 0), to: cell(1, 1)) == nil)
        #expect(g.path(from: cell(1, 1), to: cell(2, 2)) == nil)
    }

    @Test("Movement is four-way — no diagonal shortcuts through corners")
    func noDiagonalMovement() {
        let g = grid([
            ".#",
            "#.",
        ])
        #expect(g.path(from: cell(0, 0), to: cell(1, 1)) == nil)
    }

    @Test("Out-of-bounds cells are not walkable")
    func boundsAreRespected() {
        let g = grid(["..."])
        #expect(g.isWalkable(cell(-1, 0)) == false)
        #expect(g.isWalkable(cell(3, 0)) == false)
        #expect(g.isWalkable(cell(0, 1)) == false)
    }

    @Test("A rendered grid marks the route, so a wrong table is visible by eye")
    func rendersARoute() {
        let g = grid([
            "...",
            ".#.",
            "...",
        ])
        let path = g.path(from: cell(0, 0), to: cell(2, 2)) ?? []
        let picture = g.render(path: path, start: cell(0, 0), goal: cell(2, 2))
        #expect(picture.contains("#"))
        #expect(picture.contains("S"))
        #expect(picture.contains("G"))
    }
}

/// Turning a route into the input-script syntax the rest of the harness already
/// speaks, so `play` and `probe` consume pathfinder output unchanged.
@Suite("Route to input script")
struct RouteScriptTests {
    private func cell(_ column: Int, _ row: Int) -> TileGrid.Cell {
        TileGrid.Cell(column: column, row: row)
    }

    @Test("A straight run collapses into one segment")
    func collapsesRuns() {
        let path = [cell(0, 0), cell(1, 0), cell(2, 0), cell(3, 0)]
        #expect(RouteScript.script(for: path, framesPerCell: 16) == "right:48")
    }

    @Test("Each turn starts a new segment")
    func segmentsPerTurn() {
        let path = [cell(0, 0), cell(1, 0), cell(1, 1), cell(1, 2)]
        #expect(RouteScript.script(for: path, framesPerCell: 10) == "right:10,down:20")
    }

    @Test("All four directions are named as the parser expects")
    func directionNames() {
        #expect(RouteScript.script(
            for: [cell(1, 1), cell(0, 1)], framesPerCell: 8) == "left:8")
        #expect(RouteScript.script(
            for: [cell(1, 1), cell(1, 0)], framesPerCell: 8) == "up:8")
    }

    @Test("A path with no movement produces no script")
    func emptyPath() {
        #expect(RouteScript.script(for: [], framesPerCell: 16) == "")
        #expect(RouteScript.script(for: [cell(2, 2)], framesPerCell: 16) == "")
    }
}
