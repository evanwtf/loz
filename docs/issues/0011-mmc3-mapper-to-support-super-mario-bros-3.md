# #11 — MMC3 mapper to support Super Mario Bros. 3

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, emulator |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

Proves the library split works: a second game should be a new game target plus a mapper, not a fork.

The `Mapper` protocol already has the needed hooks (`currentPRGBank`, `ppuAddressChanged`, `irqAsserted`, `persistentState`), and `NES.step` already polls `mapper.irqAsserted`.

**Work**
- MMC3 bank switching (8KB PRG, 1/2KB CHR), mirroring control
- Scanline IRQ counter clocked on PPU A12 rising edges — this is how SMB3 splits its status bar
- `SMB3Game` target conforming to `GameDefinition`
- Its own app target embedding its own ROM

A12 filtering needs care: spurious edges from consecutive pattern fetches cause wrong IRQ timing and visible tearing.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
