# iOS app

`Apps/ZeldaiOS.xcodeproj` builds `Zelda.app`. It launches straight into the
game — no ROM picker, no menu.

## Supplying the ROM

**The app ships no `.nes` file.** The cartridge image is compiled into the
binary as Swift source, so there is no bundle resource and no way for the app
to fail to find one at launch.

Generate it once from your own dump:

```sh
swift run nesrun embed zelda.nes
```

That writes `Sources/ZeldaGame/ZeldaROMData.swift`. It is **gitignored** — it
holds the same bytes as the cartridge, so committing it would put in the
repository exactly what was deliberately kept out.

`GameLauncher` still verifies the image against `Zelda.expectedROMHash`, so a
wrong dump fails visibly rather than producing subtle nonsense. (A ROM file is
still accepted as a fallback, which is how the macOS build takes a path
argument.)

## Building and running

```sh
xcodebuild -project Apps/ZeldaiOS.xcodeproj -scheme Zelda \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

xcrun simctl install "iPhone 17" \
  ~/Library/Developer/Xcode/DerivedData/ZeldaiOS-*/Build/Products/Debug-iphonesimulator/Zelda.app
xcrun simctl launch "iPhone 17" wtf.evan.loz.zelda
```

## Debug builds must optimise NESCore

An interpreter is the worst possible case for `-Onone`. Measured on the iPhone 17
simulator:

| Build | Frame rate |
|---|---|
| Debug, `NESCore` at `-Onone` | **15 fps** |
| Debug, `NESCore` at `-O` | **60 fps** |
| Release | **60 fps** |

`Package.swift` therefore builds `NESCore` optimised in Debug as well:

```swift
.unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
.unsafeFlags(["-O"], .when(configuration: .debug)),
```

Without this, running from Xcode looks like a broken emulator rather than a
build-configuration artifact. The lost step-through debuggability of `NESCore`
is a good trade — it is well-tested library code, and the app and game targets
are still unoptimised.

## Launch options

Passed as `-key value` on launch; they land in the standard `UserDefaults`
argument domain. These exist so automated runs can verify the app without a
human — the simulator cannot be rotated from the command line, but the app can
rotate itself.

| Option | Effect |
|---|---|
| `-nesOrientation landscape\|portrait` | Requests that orientation at launch |
| `-nesDiagnostics YES` | Starts with the fps/bank/PC overlay visible |
| `-nesMuted YES` | Starts muted, for bulk screenshot capture |

```sh
xcrun simctl launch "iPhone 17" wtf.evan.loz.zelda \
  -nesOrientation landscape -nesDiagnostics YES
xcrun simctl io "iPhone 17" screenshot /tmp/shot.png
```

## Layout

Both orientations are supported and both are playable.

**Portrait** — screen at the top at full width, controls filling the space
below and sitting toward the bottom where thumbs rest.

**Landscape** — screen centred and as large as the height allows, with the pad
and buttons in the margins either side. Nothing overlaps the picture. On a
modern phone there is comfortably enough room for a full-size pad.

Every control dimension is derived from the available width, so the cluster
cannot overflow on any device. An earlier version padded *after* applying a
full-width frame, which pushed START and A off the right edge — worth
remembering as the failure mode to watch for.

## Controls

| Input | Action |
|---|---|
| D-pad surface | 8-way, tracked as one surface so diagonals and slides work |
| A / B | Face buttons, with haptics |
| SELECT / START | |
| MFi / Xbox / DualSense | Auto-connects; right shoulder is fast-forward |
| Hardware keyboard | Arrows, Z/X, Return, Space; P pause, R reset, D diagnostics, F fast-forward |

The d-pad is deliberately a single tracked surface rather than four buttons.
Zelda needs reliable diagonals, and discrete hit targets drop inputs when a
thumb slides between directions — which happens constantly while dodging.

## Audio

APU output plays through `AVAudioEngine`. The session uses the `.ambient`
category with `.mixWithOthers`, so the game respects the silent switch and does
not interrupt other audio.

Emulation runs on the main actor and CoreAudio drains on a real-time thread;
the queue between them is guarded by `OSAllocatedUnfairLock`, which
participates in priority inheritance. Underruns repeat the last sample rather
than inserting silence, which would click.

## Saves

Three separate mechanisms, each with a different job:

| | What it is |
|---|---|
| **Battery save** (`zelda.sav`) | The cartridge's own SRAM — the game's save files. Flushed every ~3 seconds and on exit. |
| **Save states** (4 slots) | Full machine snapshots the player chooses to keep, with thumbnails, in the in-game menu. |
| **Auto-resume** | An automatic snapshot so the app comes back where it left off. See below. |

## Sideloading to a device

Free Apple ID signing gives a 7-day provisioning profile; a paid developer
account gives a year. Set your team in the target's signing settings, then run
to a connected device. The bundle identifier is `wtf.evan.loz.zelda`.

## Auto-resume

The app snapshots itself so switching away and coming back lands exactly where
you left, with no explicit save. This is what makes a 1986 game workable on a
phone: sessions are short and interrupted, and Zelda's own save only records
progress at coarse checkpoints — it will not put you back mid-dungeon-room.

| When | Why |
|---|---|
| Scene phase `.inactive` and `.background` | The normal path. `.inactive` fires first and is where the system is most generous with time. |
| Every 20 seconds while playing | Backstop for cases where no notification arrives: out-of-memory kill, crash, force quit. |
| On `stop()` | Alongside the cartridge battery save. |

A snapshot is ~56 KB and encodes in well under a millisecond. Capture is a cheap
array copy on the main actor; **encoding and file I/O happen off it**, so the
frame loop never stalls on disk.

Restore is silent and best-effort. A snapshot from a different ROM is refused by
hash and deleted so it cannot be retried forever; a corrupt one is ignored and
the game boots normally. Nothing here should ever surface an error a player
cannot act on.

Kept in its own file, separate from the four numbered save-state slots — an
automatic write must never overwrite something the player chose to keep. There
is a toggle in the in-game menu; turning it off deletes the snapshot.

## Logging and diagnostics

The app logs through `os.Logger` under the subsystem `wtf.evan.loz`, split into
categories: `host`, `clock`, `audio`, `state`, `ui`. Unified logging is used
rather than `print` because it is persisted by the OS — the run that reproduces
a bug is usually not the run anyone was watching, and a device-only fault
diagnosed by trying to catch the console at the right moment costs several
attempts and often fails.

Read it live from a connected device:

```sh
xcrun devicectl device process launch --device <id> --console <bundle-id>
# or, without attaching to launch:
log stream --device --predicate 'subsystem == "wtf.evan.loz"' --info
```

Collect what already happened, after the fact:

```sh
log collect --device --last 10m --output /tmp/device.logarchive
log show /tmp/device.logarchive --predicate 'subsystem == "wtf.evan.loz"' --info
```

One gotcha worth knowing: the unified log **redacts string interpolation by
default**, replacing values with `<private>` when read from another process.
Every call site here marks its values `privacy: .public` deliberately — nothing
logged is sensitive, and a redacted log is a useless one.

### Diagnostics overlay

Toggle it from the in-game **⋯** menu, or launch with `-nesDiagnostics YES`.
It reports frames per second, the current PRG bank, PC, scanline, the **live
pad state**, and the **build identity**.

The last two exist because of specific dead ends. "The buttons do nothing" is
ambiguous between a press never reaching the machine and the game ignoring one
that did, and the pad line splits those apart without a debugger. The build
line answers "is the phone actually running the fix I just installed", which is
otherwise unanswerable from the device and is expensive to guess wrong in
either direction.

With diagnostics on, the frame loop also logs a budget breakdown every 120
frames:

```
perf: 60.0 fps  emulate 1.20 ms  render 0.45 ms  budget 16.67 ms
```

If `emulate + render` approaches 16.67 ms the main thread is saturated, and the
first symptom is not a visibly slow picture — display link callbacks are
privileged over touch delivery, so the game keeps animating while taps go
unread. That is what a 120 Hz display link caused before the clock was pinned
to 60 Hz.
