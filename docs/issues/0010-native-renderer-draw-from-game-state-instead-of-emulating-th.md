# #10 — Native renderer: draw from game state instead of emulating the PPU

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, decompilation |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

The final step to a true source port. Once game logic is native (#7), rendering should stop going through emulated PPU registers and OAM DMA, and instead draw tiles and sprites directly from native game state via Metal.

This is what removes the last emulated component. Only worth attempting after a substantial fraction of game logic is converted (#7) and the RAM map (#6) is well understood.

Distinct from #9, which just replaces the per-frame `CGImage` while keeping PPU emulation intact.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
