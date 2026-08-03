# #14 — Save state slots and UI in the app

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

`SaveState` snapshot/restore already works and is used by the agent harness. Surface it in the apps.

**Work**
- Multiple numbered slots, persisted to Application Support
- Quick-save / quick-load bound to controller buttons and keyboard
- Thumbnail per slot from the captured framebuffer
- Guard against loading a state captured from a different ROM (`SaveState.romHash` is already carried, but the apps currently pass an empty hash — populate it)

Distinct from the cartridge battery save, which is already persisted automatically.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Implemented. Four slots with thumbnails, persisted to Application Support per game.

Snapshots carry the ROM hash and are refused if it does not match, so a state from a different dump cannot load as subtly-wrong nonsense.

Backed by 6 tests, including a determinism check: two machines restored from the same snapshot must produce identical state after running 20 more frames — verifying the snapshot is complete rather than just plausible-looking at rest. Mapper banking is covered too.
