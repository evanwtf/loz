# #23 — Read enemy and object state from OAM

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, decompilation |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-08-02 |
| **Author** | evandhoffman |

---

Navigation currently treats rooms as static geometry, but Zelda's rooms are mostly not static — enemies move, block doorways, and are the reason a route that worked once fails on replay. Nothing in the harness can currently answer "what else is on this screen and where is it."

OAM is the cheap half of the answer: sprite positions are already in the emulator, no reverse engineering required. The expensive half — which RAM slots hold enemy type, health, and state — is exactly the work #6 exists for, and this is a good forcing function for it.

**Work**

- Read OAM into a list of (x, y, tile, attributes), grouped into logical entities — Zelda draws most enemies as 2x2 sprite groups, so raw OAM entries need clustering
- Distinguish Link from everything else (sprite 0 and its companions)
- Report from `nesrun play`/`probe` alongside the existing `--watch` output
- Correlate sprite groups with RAM to find the enemy slot table, and record findings in `Zelda.symbols` — this is the deliverable that lands in #6
- Room-clear detection: Zelda gates locked doors on enemy count reaching zero, so knowing when a room is clear is what makes "fight, then proceed" scriptable at all

**Depends on nothing.** OAM is already in `SaveState`. The RAM correlation half benefits from #22 but does not need it.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (2)

### evandhoffman — 2026-07-31

Landed in 01aae65 — OAM reading plus a closed-loop room clearer.

`nesrun oam` lists what the PPU is actually drawing, split into Link / enemies / items. `nesrun clearroom` closes the loop: every 8 frames it reads OAM, walks at the nearest actor, and swings in range.

**Result on Level 1 room $72:** `CLEARED in 252 frames, 5 swings, 24 pickups, 0 enemies left`, key collected ($066E=01), one hit taken. The fixed-script version managed 90 swings for one kill, and an earlier attempt got Link killed outright.

Two classification rules carry the whole thing, and both were wrong on the first try:

- **Status bar sprites are not actors.** Hearts and item icons live above the playfield and were being targeted as enemies.
- **One sprite is an item, two is an enemy.** Zelda runs the PPU in 8x16 sprite mode, so actors are sprite pairs and floor pickups are singles. Before that rule existed a dropped key counted as an enemy that would not die — 552 swings and 6000 frames spent attacking something Link only had to stand on.

Also needed: 'cleared' requires 6 consecutive empty observations, because a dying enemy stops drawing for a few frames before its replacement appears and a single empty read reported CLEARED on a room that still had a Keese in it.

`Entities` went into `NESAnalysis` rather than the CLI specifically so it could be tested — 10 new cases, each one a mistake listed above. Suite is 180 tests / 16 suites.

**Still open on this issue:** correlating sprite groups with RAM to find the enemy slot table and land symbols in #6. The sprite-side half is done.

### evandhoffman — 2026-08-02

Done. Every item on this issue is implemented; the last one — correlating sprite groups with RAM — landed in c5adfad.

## What shipped

| Item | Where |
|---|---|
| Read OAM into (x, y, tile, attributes) | `Entities.sprites` — excludes off-screen (Y ≥ `$EF`), status-bar sprites above the playfield, and the X=0 parking spot, all three of which appeared as phantom actors on the first run |
| Cluster into logical entities | `Entities.cluster` — single-link clustering at a tile-sized radius, since Zelda draws actors as sprite groups |
| Distinguish Link from everything else | `Entities.classify` — by position against `$0070`/`$0084` rather than by tile index, so no sprite table is needed |
| Report from the harness | `nesrun oam`, plus the loop inside `clearroom` |
| Room-clear detection | `clearroom` — closed loop over OAM, not a replayable script |
| **Correlate with RAM to find the enemy slot table** | **`$0350`, now `enemyTypes` in `Zelda.symbols`** |

## The slot table

One byte of type per slot, zero when empty:

| Room | Enemies | `$0350-$0352` |
|---|---|---|
| `$72` | 3 Keese | `1B 1B 1B` |
| `$63` | 3 Stalfos | `2A 2A 2A` |

Method, which is the part worth reusing: `ramdiff --control` **failed here, and failing was informative**. Enemies move constantly, so everything holding their state also moves in the control run and gets subtracted along with the noise. Control subtraction finds a byte that changed once; it cannot find an array that changes continuously.

What worked was looking for structure instead — snapshot a room with enemies alive, clear it, and search for a contiguous run that went non-zero to zero. Exactly one candidate of length 3 came back. Written up in `docs/agent-harness.md`.

## One finding that changes `clearroom`

`oam` reported **two** of the three Stalfos in `$63`. The third had not been drawn yet; the slot table had all three the whole time.

So sprite counting undercounts a room, and `clearroom`'s "0 enemies left" can fire early. It has not caused a visible failure yet — it walks for pickups afterwards, which absorbs the timing — but `$0350` is the correct signal and is now available. Filed as a follow-up rather than fixed here, since it is a behaviour change to a loop that currently works.

Closing; the remaining symbol-map work continues in #6.
