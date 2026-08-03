# #16 — Differential test harness for decompiled routines

| | |
|---|---|
| **State** | closed |
| **Labels** | decompilation, testing |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

The dispatch mechanism is in place (`RoutineTable`, `NES.dispatchNativeRoutine`, tested). What is missing is the verifier that makes conversion safe.

**Design**
For a candidate routine:
1. Snapshot machine state
2. Run the interpreted 6502 to its `RTS`
3. Restore the snapshot, run the native Swift version
4. Assert identical A/X/Y/SP/P, identical RAM deltas, and identical PPU/APU register writes **in the same order**

Cycle counts should be compared too, since the PPU is clocked from them.

**Work**
- Snapshot/restore already exists (`SaveState`) — reuse it
- Record memory writes during each run for ordered comparison
- Drive with many randomized entry states, not just one, to catch flag-edge bugs
- Wire into `swift test` so every converted routine stays permanently regression-tested

Without this, decompilation is guesswork. With it, each conversion is mechanically proven equivalent to the 6502 it replaces.

Blocks #7.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Implemented and proven. `RoutineVerifier` runs the interpreted 6502 and the native Swift version from identical machine state, comparing registers, flags, RAM deltas, and the **ordered** write sequence.

Two bugs in the harness surfaced on first real use, both worth recording:
- NMIs fired mid-routine and executed the game's whole frame handler — 13,792 writes against the native run's 3. Fixed by stepping the CPU alone rather than the machine.
- A restored save state carries whatever bank was live when captured, so verification was executing the wrong bytes entirely. The routine's bank is now forced before running.

There is a negative-control test: it feeds the verifier a deliberately wrong implementation (the two order-sensitive $4015 writes collapsed into one) and asserts rejection. Without that, a verifier that passes everything looks identical to one that works.
