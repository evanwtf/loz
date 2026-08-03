# #7 — Decompile bank 0 engine routines to Swift

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, decompilation |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

The long haul. Bank 0 is **79% code** — the densest bank and the engine core — so it is the right place to start.

**Approach** (incremental, always-playable)
1. Pick a leaf routine (calls nothing else)
2. Write the Swift equivalent
3. Verify with the differential harness (#16)
4. Register in `Zelda.nativeRoutines`
5. Repeat, working up the call graph

The game stays playable at every step: unconverted routines keep running interpreted.

**Blocked by**: #5 (discovery, to find the routines) and #16 (verification, to trust the conversions). Symbol names come from #6.

Track progress as converted-routine count against the discovered total.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

First two routines converted and running natively, establishing the full loop end to end:

| Routine | What it does |
|---|---|
| `00:9D42 resetAudio` | Order-sensitive $4015 writes — silence all channels, then re-enable |
| `00:BF98 writeMapperRegister` | MMC1 serial 5-bit register protocol |

Both proven equivalent across 48 randomised entry states via #16, and Zelda boots to the overworld with `resetAudio` executing as Swift.

The workflow is now repeatable: trace to discover (#5) → disassemble → decompile → verify (#16) → register. Candidate selection is easy — filtering bank 0's listing for routines with no JSR/JMP surfaces the leaves.
