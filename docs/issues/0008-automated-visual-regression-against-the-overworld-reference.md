# #8 — Automated visual regression against the overworld reference map

| | |
|---|---|
| **State** | closed |
| **Labels** | tooling, testing |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

`Reference/overworld-first-quest.png` (map by Rick N. Bruns, NESMaps.com) is geometrically exact:

```
Full image   4352 x 1408
Legend       leftmost 256 px
Map area     4096 x 1408 = 16 x 8 screens of 256 x 176
screen(col,row) -> x = 256 + col*256, y = row*176
```

That makes it usable as machine-checkable ground truth, not just a reading aid.

**Work**
- Slice the map into 128 per-screen references
- Walk the emulator to a given screen and compare its play area (rows 64-239) to the crop
- Compare structurally, not pixel-exactly: the reference has no Link, no enemies, and a different palette table. Downsample or compare tile structure and score similarity.
- Report a per-screen pass/fail grid so a rendering regression anywhere in the overworld is caught automatically

Pairs with #5: a route that visits every screen both validates rendering and maximises code coverage.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Implemented as `nesrun mapcheck`.

Structural comparison rather than pixel: both the rendered play area and the map crop are reduced to a grid of block luminances and correlated, so terrain dominates and Link/enemies/palette differences do not.

Measured across five screens: **0.949–0.999**.

Worth recording: $38 initially scored **0.404** and looked exactly like a rendering bug. It wasn't — `navigate` snapshots on arrival, sometimes mid-scroll, so the frame was a composite of two screens. Walking Link further showed the bridge and statue rendering perfectly. Settle time is now 90 frames.

Also noted in the docs: correlation is unreliable on low-variance screens (large uniform water or darkness). A single low score is a prompt to look, not proof of a defect.
