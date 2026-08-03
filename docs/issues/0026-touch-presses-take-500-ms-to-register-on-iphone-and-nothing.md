# #26 — Touch: presses take ~500 ms to register on iPhone, and nothing visible confirms a press — add activation callouts

| | |
|---|---|
| **State** | closed |
| **Labels** | bug, enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-08-01 |
| **Author** | evandhoffman |

---

Two linked problems reported on the iPhone 15 Pro (build 5afa144, with the #25 frame-pacing fix installed):

1. **A press only registers after holding for roughly 500 ms.** Deterministic, short, nothing like #25's 5–15 s — do not reopen #25 for this.
2. **The finger covers the control, so there is no visible confirmation a press landed.** Requested fix: floating activation callouts in the dead space between the game display and the controls — press up on the d-pad and a small box labelled UP appears, connected to the pad by a thin line; same for DOWN / LEFT / RIGHT / A / B / SELECT / START.

**Order matters: diagnose and fix the latency first.** Callouts built on a press state that arrives 500 ms late will faithfully show the lie.

## Part 1 — the ~500 ms press latency (bug)

### Ruled out by reading the code — do not re-investigate

- **The gesture recognisers.** Every control uses `DragGesture(minimumDistance: 0)`, whose `onChanged` fires on touch-down. There is no `LongPressGesture` anywhere (its 0.5 s default would have been the tidy explanation — it is not present). No competing gestures in `EmulatorView`; the only other touch target is the ⋯ menu button, top-trailing.
- **The input path after the gesture.** `host.setButton` is called on the same line that sets the visual pressed state; haptics fire after it. Nothing queues.

### Prime suspect: system edge gestures holding the touch

The control cluster sits at the very bottom of the screen by design ("that is where thumbs actually rest"), and `EmulatorView` applies `.ignoresSafeArea(edges: .bottom)`. Touches that begin near the home-indicator edge are candidates for the system swipe-up gesture: unless the app asks to defer it, iOS **withholds the touch from the app's gestures while its own recogniser decides**, delivering a few hundred milliseconds later. A stationary hold registers exactly when the system recogniser times out — which is precisely "hold ~500 ms and the press lands." It also explains why the ⋯ menu (top of screen, away from the edge) never felt laggy.

### Confirm on device first — no new build needed

The diagnostics overlay already prints live pad state (`pad U L …`), refreshed with the frame. With the overlay on (⋯ → Diagnostics), touch and hold a button:

- The `pad` line lags physical contact by the same ~500 ms → the delay is in **touch delivery**, before `setButton` — consistent with edge-gesture deferral. Proceed below.
- The `pad` line updates instantly but the game responds late → the delay is **downstream** of `setButton` (the game only polls the pad at its own input-read point, or something in the frame path). Different bug; stop and investigate that instead.

### Fix direction (if delivery is confirmed)

`UIViewController.preferredScreenEdgesDeferringSystemGestures` returning `.bottom` (consider all edges — in landscape the clusters run the full height, so the d-pad and buttons also sit near the bottom edge). SwiftUI exposes no modifier for it, and the app root is a plain `@main App`/`WindowGroup` (`Apps/ZeldaiOS/ZeldaApp.swift`), so the fix is a small `UIViewControllerRepresentable` whose subclassed controller overrides the property, installed behind `GameLauncher`. Deferring means the system gesture needs a *second* deliberate swipe — correct for a game.

## Part 2 — activation callouts (feature)

### Design

- One callout per **active** button, shown for as long as it is held (state, not a toast): the question being answered is "is my press registered *right now*?"
- Floating rounded label (UP / DOWN / LEFT / RIGHT / A / B / SELECT / START) in the HUD idiom — white on translucent dark, rounded font, matching the diagnostics overlay and buttons — joined to its control by a thin 1 pt connector line.
- Placement: **portrait**, in the band between the bottom of the 4:3 screen and the top of the control cluster (on a 19.5:9 phone that band is ~200+ pt — plenty); **landscape**, in the dead space above/below the centred cluster inside each side column. Each control gets its own anchor zone so simultaneous presses (d-pad diagonal + A + START) cannot collide.
- `.allowsHitTesting(false)` — callouts must never eat or delay a touch, least of all while fixing a touch-latency bug.

### State flow — hoist, don't poll

Pressed state currently lives as private `@State` inside `DPadControl`, `ActionButton`, and `SystemButton`. Hoist a single `activeButtons: NESButton` into `TouchControls`, mutated by the children on exactly the same transitions that call `host.setButton`. A callout then means **"the emulator has been told this is down"** — which also makes Part 1's latency (or its fix) visible at a glance, complementing the haptic with sight. Do not poll `controller1.buttons` on a timer to drive UI.

### Geometry

Extend `ControlMetrics` (pure geometry, no SwiftUI, per the existing pattern) with per-control callout anchor points, so `ControlLayoutTests` covers callout placement in **both** orientations alongside the existing cluster tests.

### Verification (acceptance criteria)

- [ ] Latency: after the Part 1 fix, a press shows in the overlay `pad` line within a frame or two of touch-down on the physical phone.
- [ ] Callouts appear for every button and all four d-pad directions (plus diagonals), track hold/release, and never intercept touches.
- [ ] **Screenshots in both orientations** — the standing rule, and once bitten already (`ControlLayoutTests` passed while portrait controls sat off-screen). `simctl` cannot hold a touch, so add a launch option (alongside `-nesDiagnostics`, `-nesOrientation`) that forces chosen buttons to read as held, purely so screenshots capture the callouts.

## Out of scope

- Changing control sizes or layout — the cluster stays where thumbs rest.
- The Metal renderer (#9) — callouts are ordinary SwiftUI and cheap either way.


---

## Comments (2)

### evandhoffman — 2026-07-31

Reviewed against the code and on a simulator. The code reading in this issue holds up — I re-checked and there is no `LongPressGesture`, `delaysTouchesBegan`, `simultaneousGesture`, or competing recogniser anywhere in `Sources/`; all three controls really do use `DragGesture(minimumDistance: 0)` and call `host.setButton` before the haptic. Sequencing Part 1 before Part 2 is right.

Three corrections, one of them significant.

## 1. The bottom inset was being silently discarded — fixed in 691ae25

`ControlMetrics.portrait` computes `bottomInset = height * 0.10` (57 pt on an iPhone 17), `ControlLayoutTests` asserts it, and `totalHeight` accounts for it. The view then threw it away:

```swift
.frame(width: size.width, height: size.height, alignment: .bottom)
.padding(.bottom, metrics.bottomInset)   // outside the frame — no-op
```

The `.frame` has already claimed the full height, so padding outside it cannot push anything up. It just overflowed below the container and was clipped. **The cluster sat flush against the bottom of the display, with the d-pad's DOWN key cut off by the screen edge** — so the lower half of the pad was inside the home-indicator gesture strip, not merely near it.

That materially strengthens the edge-gesture hypothesis, and it is a visible clipping bug in its own right. Fixed by swapping the two modifiers, verified by screenshot in both orientations. Landscape is unaffected (its inset is zero and it uses a different layout path).

This is exactly the class of fault `ControlLayoutTests` documents itself as unable to reach — view composition, not geometry — and again only a screenshot caught it.

**Re-test on the phone before writing any UIKit code.** The controls have moved 57 pt off the edge; if that alone fixes the latency, Part 1 is done.

## 2. The landscape claim is wrong — and it gives a free discriminator

> in landscape the clusters run the full height, so the d-pad and buttons also sit near the bottom edge

They don't. Landscape centres both clusters vertically with ~100 pt of clearance below. Deferring `.all` is still harmless, but the justification is false.

More usefully, this makes two zero-cost experiments available before any build:

- **Rotate to landscape and retry.** If the ~500 ms persists where nothing is near an edge, it is not edge deferral and Part 1 needs rethinking.
- **In portrait, compare START against d-pad DOWN.** START sits ~110 pt up, B about 20 pt, DOWN was at zero. If latency scales with proximity to the edge, that is near-proof; if START lags identically, edge deferral is dead.

## 3. The proposed fix may quietly no-op

`preferredScreenEdgesDeferringSystemGestures` is queried on the window's **root** view controller, following `childForScreenEdgesDeferringSystemGestures`, which defaults to nil. A `UIViewControllerRepresentable` planted under `GameLauncher` is a *child* of the hosting controller, and whether `UIHostingController` forwards to it is not documented. The risk is that it has no effect and gets misread as "the hypothesis was wrong."

If it comes to that: log inside the property getter — if it is never called, the override is not being consulted, which is a plan bug rather than a refuted hypothesis — and call `setNeedsUpdateOfScreenEdgesDeferringSystemGestures()` from `viewDidAppear`.

## Two smaller notes

- The overlay discriminator works **only while the picture is visibly animating**. If the main thread is saturated, the `pad` line and the picture stall together and a lagging `pad` proves nothing. Worth stating because #25's fix is still unconfirmed — and this issue asserts the two are unrelated without taking the measurement that would establish it. The installed build already logs the `perf:` line, so it is free.
- Part 2's proposed launch option that forces buttons to read as held must drive **only** the hoisted `activeButtons` UI state, never `host.setButton` — otherwise screenshot runs feed phantom input to the game.

## Revised order

1. ~~Apply the bottom inset~~ — done, 691ae25.
2. Re-test on device. Try landscape, and START vs DOWN, to isolate.
3. Only then `preferredScreenEdgesDeferringSystemGestures`, with the getter-logging guard.
4. Part 2 unchanged.

### evandhoffman — 2026-08-01

Fixed and confirmed on device. There were **two independent faults**, which is why partial fixes kept moving the symptom around rather than removing it.

## Fault 1 — the picture was not reaching the screen

`frame` was `@Published` on `EmulatorHost`, and `EmulatorView` observed that host. SwiftUI invalidates an observer when *any* published property changes, so a new picture 60 times a second rebuilt the entire view tree 60 times a second.

A screen recording measured the result: across 54 seconds the game picture changed in **33 of 216** quarter-second samples, with one unbroken stretch of **twenty seconds** in which it did not change at all — while the frame clock reported a steady 60 fps, a 16.7 ms tick gap and no late ticks throughout. Frames were being *produced* 60 times a second and *shown* about three.

Fixed in 0528b9c by giving the picture its own observable object, observed only by the view that draws it. The diagnostic counters needed the same treatment (`inputLatency` most of all — it updates on every drag event, so leaving it on the host rebuilt the controls continuously while a finger was down).

## Fault 2 — SwiftUI gesture arbitration

With rendering fixed the game was still unplayable, and the numbers finally isolated it: UIKit delivered a touch to the app in **13 ms**, while the `DragGesture` handler ran **hundreds of milliseconds** later. Behaviourally, a d-pad direction had to be held for over a second before Link took a step.

`DragGesture(minimumDistance: 0)` fires on touch-down, but a gesture recogniser must first win arbitration against every other recogniser in the hierarchy. `touchesBegan` has no such negotiation — the view is first responder and hears about the touch immediately.

Fixed in 8369a36: all three controls now read touches directly through `RawTouchSurface`.

## Also fixed along the way

| | |
|---|---|
| 691ae25 | `ControlMetrics.bottomInset` was computed, asserted by tests, and then discarded — `.padding` applied *outside* a `.frame` cannot inset anything. The d-pad's DOWN key was clipped off the bottom of the display. |
| 4189300 | Diagnostics overlay sat on top of the game picture. |
| c9be0db | The d-pad was the only control whose gesture lived inside a `GeometryReader`, which re-resolves whenever the tree is invalidated. |
| e00a7ba | Press callouts hoisted held state into `TouchControls` as `@State`, so every press rebuilt all four gestures — the frame-rate fault again, triggered by touching instead of drawing. |

## Part 2 — activation callouts

Done. Map-pin labels in the empty band above each cluster, pointing back at it. The first attempt drew a dot on the pressed d-pad arm, which is exactly where a thumb is — invisible when it matters. The row reserves its height whether or not anything is held, since a cluster that moves when a callout appears would shift the controls under the thumb pressing them.

`-nesHoldButtons up,a` forces buttons to draw as held so the callouts can be screenshotted; a simulator cannot hold a touch. It seeds visual state only and never reaches `setButton`.

## Apple's virtual controller

Added as an alternative (**⋯ → Apple on-screen controls**), since `GCVirtualController` draws in a system-owned window entirely outside SwiftUI. Two constraints, both established with a standalone `PadTest` app now in `Apps/PadTest`:

- **The d-pad only draws in landscape.** In portrait the face buttons appear and the left-hand element is silently omitted — no error, and `elements` reads back exactly what was requested. Enabling the option now rotates to landscape.
- **Requesting a direction pad *and* a thumbstick terminates the app** on connect.

`allElements` cannot be used to check this: it describes the `extendedGamepad` profile and always lists a full Direction Pad regardless of what is drawn.

## Corrections to this issue's original analysis

- The prime suspect — screen-edge gesture deferral — was **wrong**. Moving the cluster 57 pt clear of the home indicator changed nothing.
- The claim that landscape clusters "sit near the bottom edge" was wrong; they are centred with ~100 pt of clearance.
- The simulator was **not** at fault for the missing d-pad. It behaved identically to the device in both orientations and was reporting the truth throughout.

## What made this hard

Four instruments reported confident nonsense before reporting anything true: a latency check that silently discarded every sample and displayed `0 ms`; a clock whose epoch produced a reading of 25 years; a calibrated version of the same that alternated between 0 ms and 757 ms; and a gesture timer that measured hold duration rather than latency. The rules distilled from that are now in `docs/ios-app.md` under "Writing a diagnostic that can be trusted".

The measurement that actually resolved it — `gest`, timing delivery → handler — was the one requested at the outset and the last one built.
