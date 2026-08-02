# macOS and tvOS

Two targets that share everything with the iOS app except how you get input into
them. See [ios-app.md](ios-app.md) for the parts they have in common — audio,
saves, auto-resume, diagnostics.

## `zeldamac` — the fast iteration loop

A macOS build that runs **straight from SwiftPM**, with no Xcode project, no
signing and no deploy step:

```sh
swift run -c release zeldamac zelda.nes
```

The ROM path is the first non-flag argument, defaulting to `./zelda.nes`. Unlike
the iOS app, this one reads the cartridge from disk, so a re-dump does not need
`nesrun embed` first.

Relaunch is about a second. That is the whole point of the target: while working
on the PPU or a decompiled routine you want the edit-run cycle to cost nothing,
and `Apps/ZeldaiOS.xcodeproj` cannot give you that.

Controls are the keyboard, or any connected MFi/Xbox/DualSense controller:

| Key | Action |
|---|---|
| Arrows | D-pad |
| Z / X | B / A |
| Return / Space | START / SELECT |
| P | Pause |
| R | Reset |
| D | Toggle diagnostics |
| F | Fast-forward (4×) |

### Two things it has to do that a bundled app gets for free

Both are in `Sources/zeldamac/main.swift` and both are load-bearing:

- **`app.setActivationPolicy(.regular)`.** A SwiftPM executable is not an app
  bundle, so it launches as a background accessory. Without this the window
  never takes focus and every keystroke goes somewhere else.
- **`window.makeFirstResponder(window.contentView)`.** Keyboard input goes
  through SwiftUI's focus system, so the hosting view has to actually be first
  responder.

If keys stop working in `zeldamac` but work in the iOS simulator, suspect these
before suspecting `KeyboardControls`.

## `zeldamac --selftest`

A headless check of the entire host — emulation, framebuffer, and audio — with
no window and no display link:

```sh
$ swift run -c release zeldamac zelda.nes --selftest
self-test: The Legend of Zelda
  frames rendered:   300 in 0.50s (605 fps headroom)
  framebuffer image: present
  distinct colours:  12
  audio produced:    220081 / 220500 expected (99.8%)
PASS
```

It runs 300 frames (five seconds of game time) and exits non-zero unless all
three hold:

| Check | Catches |
|---|---|
| A framebuffer image exists | The render path produced nothing at all |
| More than two distinct colours | A blank or single-colour screen |
| Audio within 95–105% of the expected sample count | An APU that has stopped, stalled, or run at the wrong rate |

The reason it exists is that the frame clock cannot run everywhere the code
needs checking. Over SSH, on a sleeping display, or on a CI runner with no
session, `CADisplayLink`/`NSTimer` will not drive frames — so "does the macOS
path still work?" was previously unanswerable without sitting in front of the
machine. The self-test answers it by calling `host.tick()` in a loop instead.

The `fps headroom` figure is also the cheapest performance regression check
there is: it is how many frames per second the emulator *could* produce with no
display to wait for. If it drops toward 60, something has become expensive.

It is not in CI, because it needs the ROM.

## tvOS

`Apps/ZeldatvOS.xcodeproj`. The app itself is fifteen lines — `GameLauncher`
with no arguments — because everything platform-specific already lives in
`NESPlayer`.

The one real difference is input. There is no touchscreen and the Siri Remote is
not a usable game controller, so `GameControllerSupport` shows a "Connect a game
controller" overlay whenever none is attached, naming Xbox, DualSense, and MFi
explicitly. Without that, an Apple TV with no controller paired looks like a
frozen game.

### It has never been compiled

Stated plainly because it is easy to assume otherwise: the tvOS **platform
component** is not installed on the development machine, so this target has
never been built, let alone run.

**Do not check this with `xcodebuild -showsdks`** — it lists tvOS regardless.
The only reliable test is attempting a build, which fails with:

```
tvOS N is not installed. Please download and install the platform from
Xcode > Settings > Components.
```

Treat the target as written-but-unverified. It compiles against the same
`NESPlayer` the other two apps use, so the risk is concentrated in the
`#if os(tvOS)` branches — `GameControllerSupport` and `AudioOutput`'s session
configuration — rather than spread across the codebase.
