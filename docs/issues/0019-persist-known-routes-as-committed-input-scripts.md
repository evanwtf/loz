# #19 — Persist known routes as committed input scripts

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

Route knowledge worked out by driving the game is currently held in `.state` files under `/tmp`. Those are gitignored, ephemeral, and expensive to re-derive — working out one dungeon room by coordinate sweep costs minutes of wall time, and re-deriving a route already known is pure waste.

`docs/scripts/boot-to-overworld.txt` is the pattern to follow. It exists precisely so snapshots never need committing: the script is the reproducible thing, the snapshot is the disposable artifact.

**Currently unpersisted**

- **Sword route** — from the overworld start to the cave, and out with the sword (`$0657 = 01`).
- **Level 1 interior** — entrance room `$73`, room `$72` for the key (`$066E = 01`), and the locked door into `$63`, which takes `wait:50,right:20,down:60,right:64,up:260`.

The overworld route to Level 1 *is* already documented (`docs/agent-harness.md`, "Known route to Level 1"); this is the part that stops where the dungeon starts.

**Work**

- One script per milestone in `docs/scripts/`, named for its destination
- Each script starts from a named predecessor state so they chain rather than each replaying the boot
- A short header comment in each: what state it starts from, what it achieves, which RAM address proves it worked
- Cross-reference from `docs/agent-harness.md`

**Done when** a clean checkout plus `zelda.nes` can reproduce every state currently sitting in `/tmp`, with no snapshot committed.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (2)

### evandhoffman — 2026-07-31

Progress — sword route landed in 9aa5618.

`docs/scripts/sword.txt` reproduces from a clean boot: `boot-to-overworld.txt` then `sword.txt` leaves $00EB=77, $0657=01, Link back outside at the cave mouth.

Two things the route turned up that were worth recording in the script header:

- The cave is up-and-**left** of the start position, not straight up — straight up walks off the screen north to $67.
- At x $70 Link walks straight past the sword. x $78 is what touches it; the working window is only about 4px wide.
- **Caves do not change $00EB.** It stays $77 for the whole detour, so $0657 is the only thing that proves the sword was taken. Worth knowing before writing any cave-entering route.

Input scripts now support `#` comments and line breaks, so each script carries its own header — what it starts from, what it achieves, and which RAM address proves it.

Level 1 entry and the dungeon interior next.

### evandhoffman — 2026-07-31

Done — fe21a03 completes the set.

`docs/scripts/` now holds the whole chain, each script carrying a header saying what it starts from and which RAM address proves it worked:

| Script | Achieves | Proof |
|---|---|---|
| `boot-to-overworld.txt` | Title/registration to the start screen | `$00EB = 77` |
| `sword.txt` | Wooden sword from the cave | `$0657 = 01` |
| `to-level1.txt` | Overworld to Level 1, in through the door | `$00EB = 73` |
| `level1-key-room.txt` | West into the key room | `$00EB = 72` |
| *(`clearroom`)* | Kill the Keese, collect the key | `$066E = 01` |
| `level1-locked-door.txt` | Back east, north through the locked door | `$00EB = 63`, `$066E = 00` |

Verified end to end from a cold boot. No snapshot committed.

**The chain is not uniform, and that was the main finding.** Walking legs are input scripts; the fight in $72 is `clearroom` (#23), because a script that killed three Keese once will miss them entirely next run. `docs/scripts/README.md` gives the full recipe and says which legs are which.

Input scripts gained `#` comments and line breaks so each one documents itself.

Findings recorded in the scripts and README:

- **A blocked move and an overshoot look nothing alike.** Identical end positions across every candidate in a sweep means the input is doing nothing — Link is boxed in by bushes, or standing in a door tunnel where vertical input is ignored. Move on the other axis first.
- **Dungeon doors have ~6-frame alignment windows.** The north door of $73 accepts `right:64..68` and nothing else. The overworld is far more forgiving.
- **Settle before snapshotting.** `$00EB` updates during the scroll, so a state captured right after a screen change records the previous screen — one snapshot claimed $38 and behaved like $48 until `wait:90` was added.
- **Caves do not change `$00EB`.** The sword detour stays on $77 throughout.
- **Room numbers are `(row << 4) | col`**, same as overworld screens — so $72 and $63 are not adjacent, which rules out a class of guesses before trying any.
