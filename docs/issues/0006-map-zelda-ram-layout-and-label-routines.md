# #6 — Map Zelda RAM layout and label routines

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, decompilation |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

Build the symbol map in `ZeldaGame.Zelda.symbols`. Currently only three save-slot addresses are known.

**Targets**
- Link: X/Y position, direction, animation state, health, current screen
- Inventory: sword, items, rupees, keys, bombs, triforce pieces
- Enemy slots and their state
- Room/screen state, scroll direction, transition flags
- RNG state

**Method**
- `nesrun play --watch <addrs>` to observe candidates while scripting known actions
- Diff RAM across snapshots taken before/after a specific event
- Cross-reference published community RAM maps rather than re-deriving everything

Feeds directly into readable decompiled code — `linkPositionX` beats `ram[0x70]`.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-08-02

Progress. The symbol map is at twelve entries, and — more usefully — there is now a tool and a method for adding to it instead of guesswork.

## `nesrun ramdiff`

This issue listed "diff RAM across snapshots taken before/after a specific event" as the method, but nothing implemented it, which is why the map sat at nine entries for so long.

The naive version does not work: between two states a few hundred frames apart, **177 bytes have moved** — RNG, animation counters, sprite scratch, scroll state — and the byte you want is one of them.

So `ramdiff` takes a `--control`: a second run of comparable length in which the event did *not* happen. Anything that moved there moves on its own and is subtracted. For the sword that is the same script with `up:70` (which touches it) replaced by `wait:70` — identical in every other respect. 177 changed bytes become 13 candidates, with `[0->1]` flagging the shape most searches want.

## Added so far

| Address | Symbol | How it was confirmed |
|---|---|---|
| `$0657` | `swordLevel` | Control diff against a run that skipped the pickup |
| `$066E` | `keyCount` | Same, against a room cleared without collecting |
| `$0350` | `enemyTypes` | Structure search; confirmed across two rooms |

None of these were copied from a community RAM map — each is reproducible from the committed route scripts.

## The technique that control subtraction cannot do

Worth recording, because it is a real limit. `ramdiff --control` finds a byte that **changed once**. It cannot find an array that **changes continuously**: enemies move every frame, so everything holding their state also moves in the control and is subtracted along with the noise. It returned nothing for the enemy slots and was right to.

What found them was looking for structure — a contiguous run that went non-zero to zero when a room cleared. One candidate came back, three bytes wide, and a second room confirmed the reading (three Keese `1B 1B 1B`, three Stalfos `2A 2A 2A`).

Both methods are written up in `docs/agent-harness.md`.

## Still open

Enemy *health* and *state* (the slot table gives type only), rupees, bombs, the remaining inventory items, RNG state, and room/scroll transition flags. All are now cheap to chase — the expensive part was the instrument.
