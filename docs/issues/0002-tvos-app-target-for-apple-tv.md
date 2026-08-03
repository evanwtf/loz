# #2 — tvOS app target for Apple TV

| | |
|---|---|
| **State** | verified on simulator |
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

## Still open

- **Never run on real hardware.** The simulator has no Siri Remote and no
  physical controller, so the "connect a controller" overlay and
  `GameControllerSupport`'s connect/disconnect handling are still unexercised.
- Top-shelf image.
- Sideloading to an actual Apple TV over the network.
