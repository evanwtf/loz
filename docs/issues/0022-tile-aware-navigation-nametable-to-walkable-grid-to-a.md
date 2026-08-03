# #22 — Tile-aware navigation: nametable to walkable grid to A*

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-08-02 |
| **Author** | evandhoffman |

---

`nesrun navigate` does BFS over screen transitions (`$00EB`) and, within a screen, moves by holding a direction with a perpendicular oscillation to slip through roughly one-tile gaps. That works on the overworld and is nearly useless in a dungeon: every room so far has been solved by sweeping coordinates and checking whether `$00EB` changed, which costs minutes per room and teaches nothing reusable.

The emulator already knows the room layout — it is rendering it. Reading the nametable turns blind sweeps into pathfinding.

**Work**

- Read the active nametable out of PPU VRAM into a 16x11 tile grid (Zelda's playfield below the status bar)
- Classify tiles walkable/blocked. The tile set per room is small; a table keyed by tile index, built by observing which tiles Link can occupy, is enough and is verifiable against `mapcheck`
- A* from Link's position (`$0070`/`$0084`) to a target tile or room exit
- Emit the result as an input script in the existing syntax, so output stays compatible with `play` and `probe`
- Fall back to the current sweep when the grid says no route exists — a wrong walkability table should degrade, not deadlock

**Payoff beyond dungeons.** Room-layout reading is a prerequisite for #10 (drawing from game state rather than emulating the PPU) and the walkability table is a concrete piece of #6.

**Validation.** `docs/scripts/` routes (#19) become the regression corpus: the pathfinder should reproduce or beat every hand-derived route.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
