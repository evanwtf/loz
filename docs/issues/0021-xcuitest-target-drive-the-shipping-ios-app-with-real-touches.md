# #21 — XCUITest target: drive the shipping iOS app with real touches

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, app, testing |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

The stated goal is that an agent can play the game and confirm it works without a human. That holds for the emulator via `nesrun`, but not for the actual shipping app: nothing currently drives the iOS build. `simctl` has no tap command, `idb`/`fbsimctl` are not installed, and AppleScript key events do not reach the app (#20).

XCUITest is the supported way to synthesize real touches against a running app, and unlike the keyboard workaround it runs unattended and can go in CI.

**Work**

- UI test target in `Apps/ZeldaiOS.xcodeproj`
- Accessibility identifiers on the on-screen controls — `ControlLayout`/`TouchControls` already compute d-pad hit regions, so the identifiers should sit on the same geometry rather than introducing a second source of truth
- Helper that takes an input script in the existing `wait:60,start:4,up+a:12` syntax and replays it as touches, so scripts are shared with `nesrun` instead of written twice
- Screenshot capture as test attachments
- Assert against emulator state, not pixels — the app can expose the same RAM addresses `nesrun --watch` reads

**Why it is worth the target.** It is the only mechanism that tests what actually ships: touch handling, both orientations, auto-resume across backgrounding, the SwiftUI shell. The unit suite covers layout maths and `nesrun` covers emulation; neither touches the seam between them. The portrait-controls regression lived exactly in that seam and shipped past a green suite.

**Also** — orientation coverage here would have caught that regression. See the note in `AGENTS.md` under Making Changes.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
