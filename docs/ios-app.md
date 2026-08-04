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

### The controls do not use SwiftUI gestures

They read `touchesBegan` directly, through `RawTouchSurface`. This is not a
preference; `DragGesture(minimumDistance: 0)` made the game unplayable.

A gesture recogniser must win arbitration against every other recogniser in the
hierarchy before its handler runs. Measured on an iPhone 15 Pro, UIKit
delivered a touch to the app in **13 ms** while the `DragGesture` handler ran
**hundreds of milliseconds** later — a d-pad direction had to be held for over
a second before Link took a step. `touchesBegan` has no arbitration: the view
is first responder for the touch and hears about it immediately.

If a control ever feels slow again, the `gest` line in the diagnostics overlay
is the one to read. It times delivery → handler specifically, which is the
quantity that was missing while several other timings all looked healthy.

### Apple's on-screen controls

`GCVirtualController` is available in the menu as an alternative. It draws and
hit-tests in a system-owned window, entirely outside SwiftUI, so it cannot
suffer any of the above.

Two constraints, both established the hard way with the standalone `PadTest`
app in `Apps/PadTest`:

- **The d-pad only draws in landscape.** In portrait the face buttons appear
  and the left-hand element is silently omitted — no error, and `elements`
  reads back exactly what was requested. Enabling the option therefore rotates
  to landscape.
- **Requesting a direction pad and a thumbstick together terminates the app**
  on connect. Only one left-hand element is allowed.

`allElements` is no help in diagnosing either: it describes the
`extendedGamepad` profile, not the on-screen controls, and always lists a full
Direction Pad.

## Audio

APU output plays through `AVAudioEngine`. The session uses the `.playback`
category with `.mixWithOthers`: a game's audio is part of the game, so it does
not obey the silent switch — but starting it still does not interrupt a
podcast. (`.ambient` was the original choice and meant the game was silent on
any phone that lives on silent, which is most of them.)

Emulation runs on the main actor and CoreAudio drains on a real-time thread;
the queue between them is guarded by `OSAllocatedUnfairLock`, which
participates in priority inheritance. Underruns repeat the last sample rather
than inserting silence, which would click.

## Saves

This section is what the *player* sees. The architecture behind it — where
files go per platform, which copy wins when two devices disagree, and why an
Apple TV is a different problem — is in [saves.md](saves.md).

Three separate mechanisms, each with a different job:

| | What it is |
|---|---|
| **Battery save** (`zelda.sav`) | The cartridge's own SRAM — the game's save files. Checked every ~3 seconds and on exit, but **only written when it changed**. |
| **Save states** (4 slots) | Full machine snapshots the player chooses to keep, with thumbnails, in the in-game menu. |
| **Auto-resume** | An automatic snapshot so the app comes back where it left off. See below. |

### iCloud syncing, and how to confirm it works

Two of the three sync through `NSUbiquitousKeyValueStore`: the **battery save**
on every save, and the **auto-resume snapshot** when the app goes away (not on
the 20-second timer — 13 KB every twenty seconds is a careless share of a 1 MB
budget). Both use the identifier pinned in `Zelda.entitlements`, which the phone
and the Apple TV deliberately *share* so one quest continues on the other.

### "Game saved" notices

A capsule at the top of the screen for two and a half seconds when battery RAM
is persisted: **Game saved to iCloud**, or **Game saved on this device only** in
yellow when iCloud could not be reached. The second is worth interrupting for —
it is the difference between "my other device will have this" and "it won't",
and unlike most failures the player can act on it.

They land on an event the player already expects, because Zelda writes battery
RAM at exactly the moments that feel like saving: choosing Save, dying and
continuing, registering a name.

That is only true because the write is **change-driven**. The caller is a
three-second timer, and it used to write 8 KB to disk and push 8 KB to iCloud on
every single tick regardless of whether the game had touched anything — a
needless write every three seconds forever, into a 1 MB budget shared with every
other key, from a service that throttles frequent writers. It also made "saved"
an event with no meaning, since it happened constantly. Comparing the 8 KB
first costs nothing next to what it avoids, and makes the method do what its own
comment always claimed.

Nothing is shown in a build that never asked to sync (`zeldamac`): "saved on
this device" is only news when the other outcome was possible.

### The iCloud loading screen

Shown at launch while the save is fetched, then held so the outcome can be read:
a symbol, a headline, one sentence of what it means, and a countdown. **Ten
seconds total, and any input skips it** — a key, a tap, or any button on any
controller. There is a toggle for it in the game menu.

The copy is deliberately written for someone who does not know what a key-value
store is, because the person staring at an empty file screen wants to know
where their game went, not how it is stored. `SaveReport` picks one of seven
states and each says what it means for the *saved game*:

| Situation | Headline |
|---|---|
| No syncing in this build | Saved games stay on this device |
| Cannot reach iCloud | Can't reach iCloud |
| Adopted the cloud save | Saved game loaded from iCloud |
| Adopted a cloud snapshot | Picking up where you left off |
| Reachable, nothing stored | Connected to iCloud |
| Reachable, no local save | Connected to iCloud |
| Everything agrees | Saved games are up to date |

Only "Can't reach iCloud" is coloured as a warning, and it is the only one that
tells the player what to do (check they are signed in). Having no saves yet is
not a fault, and colouring it like one would alarm a new player.

When something did come from iCloud, its age is shown beneath:

```
🕐  2 hours ago — Aug 3, 2026 at 6:11 PM EDT
```

Both halves earn their place. The relative half is what a player actually
wants — *is this the game I was playing at lunch?* — and the absolute half is
what settles a disagreement between two devices, which is the only reason
anyone reads this screen closely. A resumed snapshot's time wins over the
battery save's, being the newer and more specific of the two.

"Local time zone if possible, UTC otherwise" needed **no** special case, which
was worth discovering before writing one. `TimeZone` always resolves, falling
back to GMT on a device that knows no better, and every zone can name itself —
even an odd offset returns `GMT+0:07`. A first attempt added a UTC fallback
branch that could never execute, with a test that passed vacuously through its
own `||`. What is actually worth guarding is that a clock reading is never
shown *unlabelled*, since that looks authoritative while meaning nothing on a
device in another country.

Relative wording is spelled out rather than left to `RelativeDateTimeFormatter`,
whose phrasing shifts with style and locale — which would make the one thing
worth asserting, that it reads like something a person said, untestable.

The screen closes at the later of *ten seconds after launch* and *three seconds
after there was an answer*. Without the second clause a slow check would eat
the whole budget and leave the outcome up for a moment — long enough to notice,
not long enough to read.

A test asserts none of this copy contains implementation vocabulary
(`entitlement`, `payload`, `cache`, `unavailable`, …). It is the kind of thing
that drifts back toward describing the machine every time someone edits it.

Confirming it is harder than it sounds, because **the failure mode is silence**.
A missing entitlement, a signed-out device, and a working app with nothing yet
stored all behave identically from the outside: the game loads the local file
and plays. That is the right behaviour — nobody should lose a game because they
signed out — but it means "it worked" and "it did nothing" look the same.

So the load logs which of four states it was in:

| `icloud:` | Meaning |
|---|---|
| `off` | This build never asked for syncing. |
| `unavailable` | No iCloud account, or the app is signed without the entitlement. |
| `empty` | Reached iCloud; nothing stored yet. |
| `present` | Reached iCloud and found a save. |

Watch it with Console.app — pick the device in the sidebar, then filter on the
subsystem. (The `log` CLI cannot stream from a paired device; it dropped the
`--device` flag.) On a Mac the same thing works directly:

```sh
log stream --predicate 'subsystem == "wtf.evan.loz" AND category == "state"'
```

The lines worth waiting for:

```
battery save: useRemote (icloud: present)   ← launch: took the cloud copy
save: game wrote 8192 bytes to disk         ← the player saved
sync: handed 8192 bytes to iCloud           ← and it left the device
auto-resume: taking the iCloud snapshot
auto-resume: iCloud unavailable, kept the local snapshot only
```

The save and the sync are **separate lines on purpose**. They fail
independently, and the interesting failure is one happening without the other:
a save with no matching sync is a device that never pushed, which is a very
different bug from a device that pushed and was overwritten afterwards. One
combined line cannot tell those apart, and telling them apart is usually the
whole question.

"Handed to" is deliberate too. `synchronize()` returning true means the value
is queued with the iCloud daemon — the key-value store gives **no delivery
confirmation at all**, so anything stronger would be a claim this code cannot
make. When it returns false, which is what an invalid entitlement produces, the
line says refused and the toast says local-only rather than reporting success.

**The log alone is not proof.** It shows this device reaching the store; it
cannot show the other device seeing the same key. Only the round trip does that:

1. On device A, play until the game writes battery RAM — save at the file
   screen, or die and choose Continue — then background the app.
2. Give iCloud a moment. Key-value sync is prompt but not instant, and it does
   not sync at all on a metered or sleeping connection.
3. Launch on device B and read its log. `battery save: useRemote (icloud:
   present)` is the round trip completing; `(icloud: empty)` means A never
   pushed, and `(icloud: unavailable)` means B cannot see the store at all.

If a device reports `unavailable`, check the entitlement actually survived
signing rather than assuming it did — Xcode rewrites entitlements files:

```sh
codesign -d --entitlements - --xml <path>/Zelda.app \
  | plutil -convert xml1 -o - - | grep -A1 ubiquity
```

Both apps must print the **same** identifier. Deriving it from the bundle ID is
the tempting mistake and gives the two apps separate stores that each sync
perfectly with themselves. See [gotchas.md](gotchas.md).

## Sideloading to a device

The bundle identifier is `wtf.evan.loz.zelda` and signing is automatic — set
your team in the target's signing settings and run to a connected device.

Everything else about getting builds onto hardware, including wireless install,
ad hoc distribution to someone else's phone, and why TestFlight is the wrong
tool for a build with the cartridge compiled in, is in
[distribution.md](distribution.md).

## Auto-resume

The app snapshots itself so switching away and coming back lands exactly where
you left, with no explicit save. This is what makes a 1986 game workable on a
phone: sessions are short and interrupted, and Zelda's own save only records
progress at coarse checkpoints — it will not put you back mid-dungeon-room.

| When | Why |
|---|---|
| Scene phase `.inactive` | Written to disk only. It fires first and is where the system is most generous with time — but tvOS also fires it whenever it wants an app-switcher thumbnail, several times a minute. |
| Scene phase `.background` | Written **and pushed to iCloud**. This is the one that means the app is actually leaving. |
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

**On by default** — this is a development build and the overlay is the only way
to answer "did that press register, and how late?" while holding the device.
Turn it off from the **⋯** menu, or launch with `-nesDiagnostics 0`.

Each line answers a question that was, at some point, unanswerable:

| Line | What it tells you |
|---|---|
| `fps emulated` | The frame clock is ticking. |
| `fps SHOWN` | Frames that actually reached the display. **Not the same number.** |
| `stale` | Age of the picture on screen. |
| `emu` / `img` | Work inside the tick. |
| `gap` / `late` | Spacing between ticks — main-thread health. |
| `touch` | UIKit delivery: finger → app. |
| `gest` | Handler: delivery → the code that presses the button. |
| `pad` | What the machine currently thinks is held. |
| build identity | Version, build number, and configuration. |
| git commit | Which source this binary came from — `6b2c68a`, or `6b2c68a+` when the tree had uncommitted changes. |
| build stamp | When the binary was linked. |

Those last three answer "is the device running the fix you just installed?",
which is otherwise unanswerable while holding the device. The commit is the one
worth pasting into a bug report; the timestamp only distinguishes builds for
the person who made them, and the **`+`** is the difference between "exactly
that commit" and "that commit plus whatever was in my editor".

The hash is stamped into `Info.plist` by a build phase in each app project,
because nothing in a compiled binary knows it otherwise. That means it shows in
the apps and reads `—` in SwiftPM builds (`zeldamac`), which have no
`Info.plist` — absent being the honest answer there rather than a number that
might be stale.

The distinctions matter more than any single value. Chasing one input bug, the
frame clock reported a flawless 60 fps with no late ticks throughout, while a
screen recording showed the picture unchanged for twenty seconds: frames were
being *produced* 60 times a second and *shown* three times a second. Nothing
that measured the emulator could see it, because nothing was wrong with the
emulator. `SHOWN` and `stale` exist for that.

Likewise `touch` and `gest` are separate because delivery was fine at 13 ms
while recognition took hundreds of milliseconds — one number healthy, the other
the entire bug.

A `perf:` line goes to the unified log **only when something is wrong** — 6 or
more of 120 ticks late, or below 55 fps. A healthy line every two seconds is
1,800 an hour, and it buried the save and iCloud lines a log actually gets
collected to read.

Demoting them to `debug` was tried first and achieved nothing: **Xcode's
console shows debug messages**, so the level only filters `log stream` and
Console.app, not the place the log was being read from. Not emitting is the
only thing that works everywhere.

Nothing is lost — frame timing is in the overlay continuously, which is where
it gets watched from. The 5% threshold rather than *any* late tick is because
one or two per 120 is normal on a healthy Apple TV, measured.
 Note that
`log collect` from an attached device **requires root**, which makes the log
unavailable in exactly the situation it is wanted; that is why the numbers are
on screen as well.

#### Writing a diagnostic that can be trusted

Four instruments in this app reported confident nonsense before they reported
anything true. The failures rhyme, and are worth stating:

- **Never silently discard "absurd" readings.** An early latency check dropped
  anything over ten seconds. Every reading was absurd, so it recorded nothing
  and displayed a steady `0 ms` — indistinguishable from perfect.
- **Always show the sample count.** `touch 0 max 0` reads identically whether
  delivery is instant or no event ever arrived. Opposite diagnoses.
- **Know your clock's epoch.** `DragGesture.Value.time` is a `Date` whose epoch
  is not the reference date; subtracting it from `Date()` yielded 25 years.
  Calibrating against the best sample then produced readings alternating
  between 0 ms and 757 ms — two tight modes hundreds of milliseconds apart, a
  shape with no physical meaning. `UITouch.timestamp` has a documented epoch
  (`ProcessInfo.systemUptime`) and needs no calibration.
- **Sample once per event.** `onChanged` fires continuously while a finger is
  down. Measuring on each callback turned "recognition latency" into hold
  duration: a two-second press reported as 1631 ms.

A dramatic number is not a discovery. Check the instrument first.
