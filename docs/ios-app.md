# iOS app

`Apps/ZeldaiOS.xcodeproj` builds `Zelda.app`. It launches straight into the
game — no ROM picker, no menu.

## Supplying the ROM

The ROM is gitignored and must be provided locally:

```sh
cp /path/to/zelda.nes Apps/ZeldaiOS/zelda.nes
```

The app target uses a **file-system synchronized group**, so the ROM is picked
up as a bundle resource automatically — no `project.pbxproj` edit, matching the
StationCast guardrail against hand-editing that file to add files.

At launch, `GameLauncher` verifies the ROM against `Zelda.expectedROMHash`. A
different dump fails with a visible message rather than a black screen.

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

Cartridge battery RAM is persisted to Application Support as `zelda.sav`,
flushed every ~3 seconds and on exit. Save *states* (full machine snapshots)
exist in `NESCore` and are used by the agent harness, but are not yet surfaced
in the app — see [#14](../../../issues/14).

## Sideloading to a device

Free Apple ID signing gives a 7-day provisioning profile; a paid developer
account gives a year. Set your team in the target's signing settings, then run
to a connected device. The bundle identifier is `wtf.evan.loz.zelda`.
