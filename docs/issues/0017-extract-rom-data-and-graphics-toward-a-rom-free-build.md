# #17 — Extract ROM data and graphics toward a ROM-free build

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, decompilation |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

Prerequisite for shipping without a `.nes` file, and larger than the code decompilation itself.

Most of this cartridge is **data, not instructions** — `nesrun analyze` reaches ~27% of PRG as code even counting speculation, and only 1.7% confidently.

**Work**
- **Graphics**: Zelda uses CHR-**RAM**, so tiles are copied out of PRG at runtime rather than being directly addressable. Finding them means tracing what the loader reads, then emitting the patterns as bundled assets.
- **Data**: level layouts, room definitions, text, item and enemy tables, music sequences, palettes. Identify each by watching what decompiled routines index into, then emit as *typed* Swift — a room should become a `Room` value, not an offset into a blob. That is where the port stops being a transliteration.
- **Verification**: run the native build and a ROM-backed emulator from the same input script and compare framebuffers. `mapcheck` and the differential verifier are the same idea at smaller scale.

**Note**: the ROM cannot be dropped until *every* routine is converted — a half-converted build needs the interpreter, and the interpreter needs the cartridge. No partial credit. This is why the incremental approach keeps the ROM to the very end while staying playable throughout.

See `docs/rom-free.md`.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
