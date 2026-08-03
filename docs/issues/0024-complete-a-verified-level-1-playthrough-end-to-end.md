# #24 — Complete a verified Level 1 playthrough end to end

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, testing |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

The original ask — sword, then Level 1, start to finish — is still unfinished. Progress so far, all via `nesrun`:

- Sword obtained (`$0657 = 01`)
- Level 1 entered, entrance room `$73`
- Room `$72` cleared, key obtained (`$066E = 01`)
- Through the locked door into `$63` (three Stalfos)

Stalled there because navigating each further room by coordinate sweep costs minutes and the routes were not being persisted.

**Why this is a ticket and not just a task.** It is the end-to-end acceptance test for the whole harness. A full dungeon exercises combat, item pickup, locked doors, room transitions, the dungeon map and compass, a boss fight, and a triforce cutscene — a much wider slice of the emulator than the overworld walk that `mapcheck` currently validates. If any of it is subtly wrong, this is where it shows up.

**Work**

- Finish the route from `$63` to the Level 1 boss (Aquamentus) and out
- Persist every step as committed scripts (#19)
- Capture a filmstrip of the run for visual review
- Assert the outcome from RAM: heart container gained, triforce piece obtained

**Blocked by nothing**, but #22 and #23 are what make it take an afternoon instead of a week.

**Stretch:** run the same route through the iOS app via #21, so the shipping app is proven to play a full dungeon, not just boot.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (2)

### evandhoffman — 2026-07-31

Status after building #23. **Not done — and the blocker is now precisely identified, which it was not before.**

### Progress

| Room | Result |
|---|---|
| $73 entrance | reached, scripted (#19) |
| $72 key room | **CLEARED in 350 frames, 6 swings, 1 hit taken**, key collected |
| $63 Stalfos | **not cleared — Link dies** |

### The blocker is health, not navigation and not the combat loop

Health through the route, measured:

| Point | `$066F`/`$0670` | Hearts |
|---|---|---|
| Start / after sword | `22`/`FF` | 3.0 |
| Entering Level 1 | `21`/`7E` | 2.5 |
| Entering $63 | `20`/`FD` | ~1.0 |

Arriving at the Stalfos room with one heart means a single hit is fatal, and the room has three of them.

**Why the half heart on the overworld matters so much:** at *full* health Link's sword fires beams — ranged kills that take no damage. The Leevers on $38 cost half a heart, the beams switch off, and everything downstream becomes melee, which bleeds more health. It is a self-reinforcing loss.

So the highest-value next step is a **damage-free overworld leg** so Link enters at 3/3 with beams intact, rather than any further tuning of the fight itself.

### Also learned

- **Routes are chaotic under re-segmentation.** Splitting `to-level1.txt` at different points and snapshotting between legs produced a run where Link died on a leg that succeeds when the script runs continuously — small timing differences move the enemies. The committed chain is reproducible end to end (verified twice); arbitrary re-cutting of it is not. Worth knowing before anyone 'optimises' a script by splitting it.
- **Death detection confirmed empirically** rather than assumed: `$066F` low nibble is whole hearts, `$0670` the fraction of the current one, both zero is death — matches the death animation exactly.

The combat loop now retreats after being hit and reports hits taken, which is what made the health story legible (eec32ac).

### evandhoffman — 2026-07-31

Pausing this for now — parking it in a known state rather than leaving it looking active.

**Where it stands:** $73 and $72 are done (key collected, room cleared taking one hit). $63 is where it stops, and the cause is identified: Link arrives with ~1 heart and three Stalfos need more than that.

**The one thing to pick up first when this resumes:** a damage-free overworld leg, so Link enters Level 1 at 3/3 with sword beams intact. That is the unlock — beams kill at range and take no damage, and the half heart the Leevers on $38 cost is what switches them off. Further tuning of the combat loop is the wrong end of the problem.

Everything needed to resume is committed: the route scripts (#19) reproduce the approach from a cold boot, and `clearroom` (#23) handles the fighting.
