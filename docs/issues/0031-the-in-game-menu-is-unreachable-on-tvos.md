# #31 — The in-game menu is unreachable on tvOS

| | |
|---|---|
| **State** | open |
| **Labels** | — |
| **Opened** | 2026-08-03 |
| **Closed** | — |
| **Author** | evandhoffman |

---

On iPhone the menu opens from the `ellipsis.circle.fill` button in the corner.
On an Apple TV there is no way to reach it, so save states, the auto-resume
toggle, diagnostics, and mute are all inaccessible on that platform.

The button is not the problem — it renders. Confirmed by screenshotting a real
Apple TV: it is drawn in the top-right corner, exactly where iOS puts it. The
overlay that places it is not inside `#if os(iOS)`.

Two things stop it working, and both need fixing:

- **`.buttonStyle(.plain)` suppresses the focus effect.** Even if the focus
  engine reaches the button, tvOS draws no ring or lift, so there is no way to
  see that it is selected.
- **The controller's Menu button is mapped to NES START**
  (`GameControllerSupport.swift`, `pad.buttonMenu.pressedChangedHandler =
  press(.start)`). That is the button a tvOS user would reach for, and it goes
  to the game instead.

There is also a conflict to resolve rather than design around: the d-pad and
left stick are bound to Link, so they cannot double as focus navigation. Any
fix that relies on moving focus to the button has to say what moves focus.

## Options

1. **Long-press Menu opens the app menu; a short press stays NES START.**
   Costs no button and matches how the control is already used. START arrives
   on release rather than on press, which is fine for a button used to open the
   inventory and not in combat.
2. **Reassign Menu to the app menu and move NES START elsewhere.** Cleanest
   against the tvOS convention that Menu means *menu*, but START is used
   constantly in Zelda and would have to displace something.
3. **Make the button properly focusable on tvOS** with a real focus style, and
   accept that the d-pad both steers Link and moves focus.

Option 1 looks best: it is the only one that costs nothing elsewhere.

## Notes

Worth checking against the emulator's own state, not just the UI: opening the
menu pauses the host, and on tvOS `persistForBackgrounding` is the only thing
that writes a snapshot to iCloud. A player who cannot open the menu also cannot
deliberately save.
