# #3 — macOS app target for the fast dev loop

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

macOS target sharing `NESPlayer`. Keyboard input already implemented in `KeyboardControls` (arrows, Z/X, Return, Space, plus P/R/D/F for pause, reset, diagnostics, fast-forward).

Primary value is iteration speed: no device deploy, no signing, instant relaunch while working on the PPU or decompiled routines.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Done. `Sources/zeldamac/main.swift` is an AppKit host over `NESPlayer`, launched with `swift run -c release zeldamac zelda.nes`. No Xcode project, no signing, no device deploy.

Two things worth noting beyond the original scope:

- `app.setActivationPolicy(.regular)` and `makeFirstResponder` are both required — a SwiftPM executable is not an app bundle, so it defaults to a background accessory and keyboard input goes nowhere without them.
- `--selftest` runs the whole host headlessly (emulation, framebuffer, audio) with no window or display link, so the macOS path can be verified over SSH or on a sleeping display.

Latest self-test: 300 frames in 0.49s (612 fps headroom), framebuffer present, 12 distinct colours, audio 220081/220500 samples (99.8%). PASS.
