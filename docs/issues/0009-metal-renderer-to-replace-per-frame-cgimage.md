# #9 — Metal renderer to replace per-frame CGImage

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

`FrameRenderer` currently builds a `CGImage` every frame (~245 KB of allocation at 60 Hz). Fine for a harness, wasteful in a shipping app and a likely source of jitter on older devices.

**Work**
- `MTKView` with an `.rgba8Unorm` texture updated per frame
- Nearest-neighbour sampling — pixel art must never be smoothed
- Correct 4:3 aspect with integer scaling where it fits
- Optional CRT/scanline shader
- Measure energy impact on device before and after

Separate from #10, which is about replacing PPU *emulation* entirely.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
