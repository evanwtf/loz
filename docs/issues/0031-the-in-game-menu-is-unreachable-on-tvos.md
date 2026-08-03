# #31 — Establish how the in-game menu is reached on tvOS

| | |
|---|---|
| **State** | open |
| **Labels** | — |
| **Opened** | 2026-08-03 |
| **Closed** | — |
| **Author** | evandhoffman |

---

On iPhone the menu opens from the `ellipsis.circle.fill` button in the corner.
On an Apple TV it is not obvious how to reach it, and how it behaves during
play has not been established.

**Correcting a wrong first diagnosis, which is why this is written down.** The
button was reported as unreachable on tvOS. It is not. A screenshot of a real
Apple TV shows it drawn in the top-right corner *and in its focused state* —
large and highlighted, the standard tvOS focus appearance. So the focus engine
does reach it, and `.buttonStyle(.plain)` does not suppress the effect the way
the first reading assumed.

What is actually unresolved is the **interaction between focus and gameplay**,
and it needs measuring rather than reasoning about:

- The button appears to hold focus by default at launch. If it does, what does
  the controller's A button do while it is focused — attack, or open the menu?
  Those cannot both be right.
- The d-pad and left stick are bound to Link through `GCController` handlers,
  which do not consume the events. So the same press may steer Link *and* move
  focus.
- `pad.buttonMenu` is mapped to NES START
  (`GameControllerSupport.swift`), so the button a tvOS user would instinctively
  press for a menu goes to the game instead.

## What to do first

Measure, do not design. Connect a controller and answer, with screenshots:

1. Does the menu button hold focus at launch, and does anything take it away?
2. With it focused, does A open the menu, attack, or both?
3. Does the d-pad move focus while steering Link?

Only then choose a fix. If focus already works, this may be a matter of
directing focus away from the button during play and giving the player a
deliberate way back — likely a long press on Menu, which costs no button and
leaves START where muscle memory expects it.

## Notes

Worth checking against the emulator's state and not just the UI: opening the
menu pauses the host, and `persistForBackgrounding` is what writes a snapshot
to iCloud. A player who cannot open the menu also cannot deliberately save.
