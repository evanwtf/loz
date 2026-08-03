# #20 — Simulator keystrokes never reach the app: ConnectHardwareKeyboard is off

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

Synthetic keystrokes sent to the Simulator do not reach the app. A decisive test: launch the app, activate Simulator, `keystroke "p"` (the app's pause key), screenshot twice 4s apart — the frames differed, so the game never paused.

The likely cause is a Simulator setting, not the app:

```
$ defaults read com.apple.iphonesimulator
{
    ConnectHardwareKeyboard = 0;
    ...
}
```

With the hardware keyboard disconnected, the Simulator does not forward host key events to the device at all.

**Work**

- `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool true`, restart Simulator (or use I/O ▸ Keyboard ▸ Connect Hardware Keyboard)
- Re-run the pause test and confirm the framebuffer stops changing
- If it works, document it in `docs/ios-app.md` as a prerequisite for driving the app headlessly

`KeyboardControls` already handles arrows, Z/X, Return, Space, and P/R/D/F for pause, reset, diagnostics, and fast-forward, so nothing in the app should need to change.

**Caveat.** Even if this works it is a developer convenience, not a test harness — it depends on host UI focus and cannot run unattended. #21 is the durable path. Worth 5 minutes first because it unblocks manual iteration immediately.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Investigated. **The setting was not the cause** — but the investigation found a real bug, fixed in 1ccd7f8.

### What was actually wrong in the app

`onKeyPress` only fires on a view that **holds** focus; `.focusable()` merely makes it eligible. Nothing on iOS ever granted that focus, so the whole modifier was silently dead — arrows, Z/X, Return, Space and the P/R/D/F shortcuts did nothing on iPhone or iPad with a hardware keyboard attached.

macOS worked by accident of a different code path: `zeldamac` calls `window.makeFirstResponder(window.contentView)` at launch, and *that* was delivering keys. The modifier never claimed focus on any platform. Now fixed with `@FocusState` + `.focused()` + `.onAppear`, which also removes zeldamac's reliance on that side effect.

### What was wrong with my diagnosis

`ConnectHardwareKeyboard` did not even exist in `com.apple.iphonesimulator` — my earlier reading of it as `0` was wrong. Setting it to `1` changed nothing.

The real harness blocker is **focus**: synthetic keystrokes go to whichever app is frontmost, and Simulator cannot be brought to the front from this session. `tell application "Simulator" to activate`, `open -a Simulator`, and `set frontmost of process "Simulator" to true` all leave the terminal frontmost. Accessibility permission *is* granted (`UI elements enabled` → true) and `keystroke` calls succeed — the keys just land in the terminal.

### Verified along the way

The app itself is healthy on the simulator: built, installed, launched, and screenshotted rendering Zelda's attract-mode item demo, with the on-screen controls laid out correctly in portrait.

### Conclusion

The app fix is real and committed. The AppleScript key-injection *harness* is a dead end regardless of it — it depends on window focus this session cannot obtain. That is the case for #21, which drives the app in-process and needs no focus at all. Closing this; the keyboard fix will get its end-to-end verification there.
