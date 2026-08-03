# #25 — Input lags 5-15s on physical iPhone while the picture keeps animating

| | |
|---|---|
| **State** | closed |
| **Labels** | bug, app |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-08-01 |
| **Author** | evandhoffman |

---

Input on a physical iPhone lagged by 5–15 seconds while the picture kept animating normally. A fix is committed and installed but **has not been confirmed by measurement**, so this stays open until it is.

## Status

| | |
|---|---|
| Device | Evan — iPhone 15 Pro (`iPhone16,1`), `AE80673D-A9FF-5A49-99B2-B7026A7D13B7` |
| Bundle | `wtf.evan.loz.zelda`, Release, signed Apple Development, team `94S5PZTVPY` |
| ROM | embedded (`nesrun embed`), no `.nes` in the bundle |
| Installed build | b123319 |
| Fix | 74826e0 — believed correct, **unverified on device** |

## Symptom

Tapping the d-pad or any button took 5–15 seconds to register. The game itself animated normally the whole time, which is why it first read as an input bug rather than a performance one.

## Diagnosis

The iPhone 15 Pro has a 120 Hz ProMotion display. `CADisplayLink` defaults to the display's **maximum** rate, and `FrameClock`'s callback stepped one whole NES frame per firing. So the app emulated ~120 NES frames per second and built ~120 `CGImage`s per second — double speed and double render work.

The speed error is the lesser half. Saturating the main thread stops the run loop servicing touches promptly, and display-link callbacks are privileged over touch delivery. That produces exactly the observed shape: **picture keeps moving, taps sit unread for seconds.**

Fixed at two levels in 74826e0:

- the link requests 60 Hz via `preferredFrameRateRange`
- `FrameClock` *also* paces itself against the wall clock, because `preferredFrameRateRange` is a request rather than a guarantee, and a clock that emulates once per refresh silently changes game speed depending on the attached display

## Why this is still open

**The diagnosis was never confirmed with numbers from the device.** It is inferred from the hardware and the symptom shape. Two attempts to capture on-device profiling output both failed because the phone auto-locked before `devicectl ... --console` could attach (`FBSOpenApplicationErrorDomain error 7`, "Locked").

This is plausible but not proven. The rendering path is independently expensive — `FrameRenderer` builds a `CGImage` per frame, ~245 KB of allocation at 60 Hz (#9) — so even at a correct 60 Hz the budget may still be tight.

## How to confirm (do this first)

Everything needed is already installed and committed.

1. Unlock the phone and **keep it unlocked** — this is what defeated both previous attempts.
2. Launch with profiling and capture the log:

```sh
DEV=AE80673D-A9FF-5A49-99B2-B7026A7D13B7
xcrun devicectl device process launch --device $DEV --terminate-existing \
  --console wtf.evan.loz.zelda -- -nesDiagnostics YES
```

Or read it after the fact, which does not require attaching at launch:

```sh
log collect --device --last 10m --output /tmp/device.logarchive
log show /tmp/device.logarchive --predicate 'subsystem == "wtf.evan.loz"' --info
```

3. Expect a line every 120 frames:

```
perf: 60.0 fps  emulate 1.20 ms  render 0.45 ms  budget 16.67 ms
```

**Reading it:**

- `60.0 fps`, `emulate + render` well under 16.67 ms → the fix worked, close this.
- `~120 fps` → the 60 Hz pin is not taking effect; the wall-clock pacing in `FrameClock.tick()` should have prevented this, so investigate there.
- `60 fps` but `emulate + render` near 16.67 ms → real budget problem, not frame pacing. That points at #9 (Metal renderer) as the actual fix, and this issue becomes a duplicate of it.

The in-game overlay (**⋯ menu → Diagnostics**) shows the same fps plus live pad state and **build identity**, so it also confirms the phone is running the expected build.

## Ruled out, with evidence — do not re-investigate

- **The input path.** `HostInputTests` (4 tests, 13995c7) drives `EmulatorHost` exactly as the app does — `setButton` + `tick` — replays the committed boot script to the overworld, asserts a held direction moves Link, and asserts pause stops and resumes the clock. All pass.
- **The press not firing.** The haptic call sits on the line *after* `host.setButton(...)` in the same gesture closure, and haptics were felt.
- **Two hosts / stale reference.** `GameLauncher` holds one `EmulatorHost` in `@State` and passes it to both the screen and `TouchControls`.
- **Game controller interference.** Confirmed none paired. `GameControllerSupport` only reacts to controller events; it never polls or clears.
- **Emulation being broken in Release or by the embedded ROM.** Verified running and animating on the simulator in that exact configuration.
- **The emulator core being slow.** `zeldamac --selftest` reports 300 frames in 0.49 s — ~612 fps of headroom on desktop.

## Fixed along the way (separate from the lag, all committed)

- **1ccd7f8** — keyboard input never worked on iOS at all. `onKeyPress` requires a *focused* view; `.focusable()` only makes it eligible. macOS worked by accident because `zeldamac` calls `makeFirstResponder`. A hardware keyboard on iPhone/iPad did nothing.
- **13995c7** — audio used the `.ambient` session category, which obeys the ring/silent switch, so the game was mute on any phone on silent. Now `.playback` with `.mixWithOthers`.
- **8c35453** — Start/Select had no haptic at all, and the d-pad's was `.rigid` at intensity `0.3`, below what most people can feel. Shared pre-armed generators now, since allocating one per press pays the Taptic warm-up each time and lands the tap late.
- **e1da2fb / b123319** — `os.Logger` throughout, plus build identity in the overlay.

## Known side effect worth a decision

Switching to `.playback` made the audio participate in normal media routing, so it followed a standing AirPlay route to the Mac. Correct behaviour (AirPlay/CarPlay from a game is usually wanted), fixable from Control Center. Only revisit if it turns out to be a nuisance.

## Gotcha for whoever picks this up

`swiftformat`'s `--self remove` strips `self.` from inside `Logger` message autoclosures, where Swift requires it — code builds before formatting and not after. Values are hoisted into locals before logging in `EmulatorHost` for exactly this reason; don't inline them back. This broke a commit today (e1da2fb, fixed in b123319).

Run the gate with `set -o pipefail` — piping `swift test` into `tail` masks its exit status, which is how that broken commit got pushed.


---

## Comments (2)

### evandhoffman — 2026-07-31

Reviewed 74826e0 against the code and dry-ran the confirmation instrumentation on the Mac. The diagnosis and the fix hold up; four things to know before reading the device numbers.

## What verified

- **The pacing math** (`FrameClock.tick()`): the 15 ms threshold (`interval * 0.9`) emulates every other callback at 120 Hz delivery and every callback at 60 Hz. No accumulator, so no catch-up burst after a slow frame and no debt while paused — dropped frames, not a death spiral.
- **Every "ruled out" claim spot-checked against the source**: haptic sits after `setButton` (`TouchControls.swift:167`), one `@State` host in `GameLauncher`, `HostInputTests` green, and the audio ring buffer drops on overflow, so pre-fix 2x-speed audio could not have grown unboundedly. Gates green at b123319 (184/184, lint, release build).
- **The instrumentation works end-to-end.** `zeldamac zelda.nes --selftest -nesDiagnostics YES` wrote exactly the promised line to the unified log, unredacted, every 120 frames:
  ```
  zeldamac: [wtf.evan.loz:clock] perf: 0.0 fps  emulate 1.62 ms  render 0.00 ms  budget 16.67 ms
  ```
  (`fps 0.0` is an artifact — the selftest finishes inside the first 0.5 s sample window. Note the ROM path must come before the flags; the first non-dash argument is taken as the ROM.)

## Read this before the confirmation run

1. **The in-game ⋯ → Diagnostics toggle does not produce `perf:` lines.** It is view-local `@State`; the logging reads `LaunchOptions.showDiagnostics` (UserDefaults). Only the launch argument route — `devicectl ... launch --console wtf.evan.loz.zelda -- -nesDiagnostics YES` — enables profiling. Toggling the menu shows the overlay but logs nothing.
2. **`render` ms cannot see the real render cost.** `CGImage` construction is lazy; decode/upload/composite happen in the render server, outside the timed region — which is why the Mac measures 0.00 ms while building 245 KB images. So "emulate + render ≪ 16.67 ms" does *not* by itself rule out the render path. The decision table needs a fourth row:

   | Reading | Meaning |
   |---|---|
   | 60 fps, emulate+render under budget | fix worked, close this |
   | ~120 fps | pin ignored *and* wall-clock pacer not running — check build identity in the overlay |
   | 60 fps, emulate+render near budget | real budget problem inside the tick → #9 |
   | **< 60 fps, emulate+render well under budget** | **main-thread load outside the tick (SwiftUI/render-server compositing) → #9** |
3. **The startup log line at b123319 prints the request, not the hardware** ("max available 60 Hz" on a 120 Hz phone). Ignore it on that build. Fixed in **5afa144**, which is now installed on the phone — this run's log will read `display link at 60 Hz (hardware max 120 Hz)`, and the overlay's link timestamp distinguishes it from the previous install.
4. **Latent, note-only:** the wall-clock pacer guarantees "never fast", not "always 60" — a delivered rate 16.67 ms does not divide (90/144 Hz) aliases into ~0.8x slow motion. Harmless on Apple displays (60/120, exact multiples, and the pin floors at 60); only an external display that ignores the pin could hit it. Documented at the guard in 5afa144.

Status unchanged: open until the on-device numbers land. Everything needed is on the phone as of 5afa144.

### evandhoffman — 2026-08-01

Resolved by the same work as #26, which is now closed with the full write-up.

The ProMotion diagnosis this issue was opened on was **not** the cause. The frame clock was healthy throughout — 60 fps, a 16.7 ms tick gap and no late ticks, measured on device. Two other faults produced the symptom:

1. `frame` was `@Published` on `EmulatorHost`, which `EmulatorView` observed, so every frame rebuilt the whole view tree. Frames were *produced* 60 times a second and *shown* about three — a screen recording caught the picture unchanged for twenty seconds (0528b9c).
2. SwiftUI gesture arbitration delayed the handler by hundreds of milliseconds while UIKit delivered the touch in 13 ms. The controls now read `touchesBegan` directly (8369a36).

The 60 Hz display-link pin from 74826e0 is kept — it is correct on its own terms, since one NES frame per display refresh runs the game at double speed on a 120 Hz panel. It simply was not what made input lag.

Confirmed fixed on device.
