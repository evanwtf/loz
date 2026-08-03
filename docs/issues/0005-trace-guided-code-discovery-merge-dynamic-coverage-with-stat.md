# #5 — Trace-guided code discovery: merge dynamic coverage with static analysis

| | |
|---|---|
| **State** | closed |
| **Labels** | decompilation, tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

Static analysis has plateaued. `nesrun analyze` finds **170 routines covering 27.1% of PRG**, and cannot go further:

- 5 unresolved `JMP ($xxxx)` dispatchers hide everything behind them
- MMC1 banking means a bare address does not identify code, so the analyzer over-approximates by re-tracing every entry point against all 8 banks — which produces false hits (it currently reports 'calls' into $6xxx SRAM, which is tracer noise from decoding data as code)

Execution resolves both problems exactly: the running CPU knows the live bank and the real indirect-jump target.

**Work**
- `--trace` already records executed `(bank, PC)` via `NES.onInstruction` and reports bytes static analysis missed. Build on it:
- Persist coverage across sessions and merge runs
- Record observed targets at each indirect-jump site, and feed them back as static analyzer seeds
- Report per-bank coverage growth so it is obvious which areas remain unexplored
- Script a play route (overworld, a dungeon, shop, death, save/continue) that exercises the major systems

**Goal**: get well past 170 routines with accurate bank attribution and no false positives.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Implemented. Playing the game is now the discovery mechanism.

The key trick: **the instruction executed immediately after a `JMP (indirect)` or `RTS` is its resolved destination.** Recording that converts the edges static analysis cannot follow into observed facts.

Results after boot + an overworld walk + a Level 1 tour:
- **253 routines observed** against 170 found statically — **176 that static analysis never saw**
- **244+ dispatch sites resolved**, 477 distinct edges
- Traces merge across sessions, so coverage accumulates over many short runs

Also revealing: 33,391 bytes are marked code by static analysis but never execute, which is direct evidence for the false positives tracked in #15.
