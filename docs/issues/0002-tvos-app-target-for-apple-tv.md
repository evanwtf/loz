# #2 — tvOS app target for Apple TV

| | |
|---|---|
| **State** | shipped — verified on Apple TV 4K hardware |
| **Labels** | enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

Apple TV target sharing `NESPlayer`.

**Work**
- `Apps/ZeldatvOS/` app target, top-shelf image, 1920x1080 layout
- Controller required — the Siri Remote is unusable for this game, so surface a clear 'connect a controller' state rather than failing silently
- Verify `GameControllerSupport` handles connect/disconnect mid-session
- Sideload from Xcode over the network

Blocked by nothing; `GameControllerSupport` already exists.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Note

The iCloud save sync from [#30](0030-investigate-storing-savegames-state-in-icloud.md)
is a prerequisite rather than a companion. tvOS gives apps no guaranteed
persistent local storage — the Documents directory can be purged whenever the
system wants space — so without syncing, an Apple TV build would appear to save
and then silently lose progress at an arbitrary later date. That is worse than
not saving at all.

That work is done, and the tvOS target carries the same entitlement with the
same pinned key-value identifier as the phone, so the two share one quest.


---

## Verified

Built and run on the Apple TV 4K simulator (tvOS 26.5), the first time this
target has ever been compiled.

| | |
|---|---|
| Build | clean, first attempt |
| Performance | 60 fps emulated, 60 fps shown, 0 stale, 0/120 late |
| Picture | 2720x2040 on a 3840x2160 screen — exactly 4:3, pillarboxed |
| Colour | correct |
| Auto-resume | restores a seeded overworld snapshot |
| Battery save | written, and syncing (see #30) |

That it built first time is worth recording rather than assuming: the risk was
concentrated in the two `#if os(tvOS)` branches — `GameControllerSupport` and
`AudioOutput`'s session configuration — and both were right.

**Measuring the geometry took three attempts**, and the first two conclusions
were wrong. Measuring non-black *content* is meaningless here: Zelda's own frame
is largely black, so the extents move with whatever is on screen, and the
diagnostics overlay attaches to the full-screen container rather than to the
picture. Colouring the screen view's background and measuring *that* is the only
reading that means anything. Noted because the same trap is waiting for anyone
checking the layout again.

One cosmetic point: the picture sits 120 px lower in its container than centring
would put it. Black on black, so invisible — left alone rather than adjusted on
a guess.

## Closed out on hardware

Everything that was still open here has since been done and verified on a real
Apple TV 4K, across `v0.2.0` and `v0.3.0`:

- **Runs on hardware** at a steady 60 fps emulated and 60 fps shown, installed
  over the network. The picture measures 2720x2040 on a 3840x2160 screen —
  exactly 4:3, pillarboxed.
- **Controller handling is exercised**, with a DualShock 4. The "connect a
  controller" overlay is what a controller-less Apple TV shows instead of
  looking frozen.
- **Top-shelf and app icons** are generated from the iOS icon by
  `Tools/tvos-icon.py` — eleven images at four aspect ratios (#7).
- **The scheme runs Release**, because `-O` versus `-Ounchecked` is a 3.5x
  difference for an interpreter and a Debug build presents as 30 fps on this
  hardware (#9).

Three things the simulator could never have caught, all of which needed the
device:

- **Saving was completely broken**, in three stacked ways — see
  [saves.md](../saves.md). The simulator inherits the Mac's directories, so
  Application Support exists there and the first bug is invisible.
- **Audio ran at the wrong sample rate** (#5). An iPhone's session happens to
  be 44.1 kHz, so only this platform exposed it.
- **The menu could not be reached, then could not be navigated** — see
  [#31](0031-the-in-game-menu-is-unreachable-on-tvos.md). Both need a real
  controller and a real focus engine.

The general lesson is worth keeping: "verified on simulator" was an honest
description that turned out to cover almost none of the risk on this platform.
