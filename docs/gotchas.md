# Gotchas

Things that cost real time, with the measurement that settled each one. Every
entry here was a wrong conclusion first — they are written down because the
reasoning that produced the wrong answer was reasonable, and will be reached
again.

## Audio must be generated at the hardware's rate

Symptom: on an Apple TV the music played slow and stuttered. On an iPhone it was
perfect.

`EmulatorHost` hardcoded 44100, and the APU derives everything from it:

```swift
cyclesPerSample = Self.cpuClock / sampleRate
```

That number decides how many samples a frame produces. An Apple TV over HDMI
runs at **48 kHz**, so the emulator generated 735 samples per frame where the
hardware consumed 800 — a permanent 8% deficit, every frame, forever.

**No buffer absorbs a continuous shortfall.** The ring drained, and
`AudioRingBuffer.read` repeats its last sample rather than click, which sounds
exactly like music dragging.

iOS was correct by luck: an iPhone's session runs at 44.1 kHz, so the hardcoded
value happened to match. `AudioOutput.hardwareSampleRate()` now asks the session
what it actually got.

The general shape: **a resampler is the wrong fix for a rate mismatch you
control.** Generate at the rate the hardware wants.

## Application Support does not exist on tvOS

The Apple TV read the iCloud save at every launch and never wrote one. A quest
saved on it vanished; a quest from another device reappeared in its place. It
presented as an iCloud bug and was not one.

This was one of three stacked bugs; [saves.md](saves.md#three-stacked-bugs-none-of-them-icloud)
has all three together, since each alone would have been enough to break saving
on that platform.

Every save path started from the same directory:

```swift
FileManager.default.url(for: .applicationSupportDirectory, ...)
```

**tvOS does not permit that.** An app may write to Caches and tmp; Application
Support cannot even be created. Every call site wrapped the attempt in `try?`,
so the failure became a nil URL rather than an error, and a nil URL made three
separate features exit at their first guard — battery save, auto-resume, and
the four save-state slots — silently, for the entire life of the tvOS app.

Worse, the battery save's guard read `guard let saveURL, ...`, so **having
nowhere local to write also disabled the iCloud push.** The one platform that
guarantees no persistent local storage was therefore the one platform excluded
from the syncing that exists because of it.

Two rules come out of this:

- **A platform-specific directory is a platform-specific decision.** Route it
  through one place (`SaveLocation`) rather than repeating the call at each
  site, or the next feature repeats the bug.
- **Local storage failing must not disable remote storage.** They are separate
  failures with separate consequences, and on tvOS the cloud copy is the
  record while the local file is a convenience.

It took an on-screen counter to find, because the log was unreachable: `log
collect` from a paired Apple TV needs root and then fails with "Device not
configured". `save 0@- sync 0@- never` in the diagnostics overlay is what
pointed at the guard. The frozen timestamp on the loading screen — the same
6:11 PM across three hours and several saves — is what proved nothing was
being written.

## `-O` is not `-Ounchecked`, and the gap is 3.5x

`Package.swift` builds `NESCore` with `-Ounchecked` in release and `-O` in
debug. The debug flag exists so debug builds stay playable — but `-O` is not the
same as the release build, and for an interpreter the difference is large:

```
SwiftPM debug   (-O)          300 frames in 1.84s    163 fps headroom
SwiftPM release (-Ounchecked) 300 frames in 0.53s    565 fps headroom
```

`-Ounchecked` removes bounds and overflow checks. A CPU interpreter pays those
on every single memory access, so they dominate.

On the Apple TV this is the difference between working and not: 19.2 ms per
frame in Debug against 5.8 ms in Release, where the budget is 16.7 ms. The
device ran at 47 fps and the audio dragged as a consequence. An iPhone 15 Pro
absorbs it — 8.8 ms still fits — so the same defect is invisible there.

**On the device it reads as 30 fps, not 47.** `CADisplayLink` presents on
vsync boundaries, so missing a 16.7 ms deadline does not cost a proportional
amount — it costs the whole next frame, and the rate falls to a divisor of 60.
That the number is exactly half is a useful signal in itself: gradual slowness
looks like 47, and a missed deadline looks like 30.

Which is why the tvOS scheme's **Run action builds Release** while iOS's stays
Debug. Debug is a useful configuration on a phone and not on an Apple TV, so
the platform where hitting Run cannot produce a playable build is the platform
that should not default to it. The cost is stepping through app code on tvOS,
which is fifteen lines — everything real is in `NESPlayer` and `NESCore`.

**A wrong explanation was published before this was measured.** The first
diagnosis was "Xcode applies its own `-Onone` to package targets", which is
false. Both flags appear on the command line and the *last* one wins:

| Configuration | Flags, in order | Effective |
|---|---|---|
| Debug | `-Onone` … `-O` | `-O` |
| Release | `-O` … `-Ounchecked` | `-Ounchecked` |

Xcode honours `Package.swift` correctly. Check the actual compiler invocation
before blaming the build system:

```sh
xcodebuild … | grep swift-frontend | grep -i nescore | tr ' ' '\n' | grep -nE '^-O'
```

## Xcode builds every target in a local package

Opening either app project and building failed with:

```
Sources/zeldamac/main.swift:1:8
Unable to resolve module dependency: 'AppKit'
```

The app projects reference this package **locally**, so Xcode resolves and
indexes *every* target for the selected platform — including `zeldamac`, a macOS
executable. Nothing in the iOS or tvOS app depends on it; being in the package
is enough.

`swift build` never sees this, because it builds for the host where AppKit
exists. So the package suite, the release build and all three CI jobs stayed
green while Xcode could not build the apps at all. CI's iOS job passes because
`xcodebuild` builds only what the app depends on; the failure needs the
*editor*.

Platform-specific targets need `#if os(...)` around the whole file, not just
around the parts that look platform-specific.

## Xcode rewrites entitlements files

Touching capabilities in Xcode rewrites `*.entitlements` wholesale: it strips
comments and adds keys for capabilities it thinks are enabled. It added
`aps-environment` and CloudKit keys to the tvOS target, neither of which this
app uses.

Check the diff after any capability change. The file carries a comment saying so.

## The iCloud key-value identifier must be pinned, not derived

The obvious entitlement value is `$(TeamIdentifierPrefix)$(CFBundleIdentifier)`.
It is wrong here.

The Apple TV bundle is `wtf.evan.loz.zelda.tv` and the phone is
`wtf.evan.loz.zelda`, so deriving the identifier gives the two apps **separate
stores**. Each would sync perfectly with itself and never see the other — the
exact opposite of the point, and it would have looked like working code.

Both targets name the phone's identifier deliberately.

## Building the package scheme does nothing visible

Xcode's scheme menu lists the package's own schemes — `loz-Package`, `NESCore`,
`NESPlayer`, `nesrun`, `zeldamac`. Building one succeeds and nothing launches,
because none of them is an app.

To run on a device, open `Apps/ZeldaiOS.xcodeproj` or `Apps/ZeldatvOS.xcodeproj`
— not `Package.swift`, not the repository folder. Each has a single scheme named
**Zelda**.

## A new device class needs registering, and Xcode will not always do it

An Apple TV paired to the Mac, with Developer Mode already enabled, still fails
to build:

```
error: Device "Office" isn't registered in your developer account.
```

`-allowProvisioningUpdates` did not register it, because the team had no tvOS
devices and no tvOS profile to extend. Running once from the Xcode UI with the
device selected is what offers to register it; the alternative is adding the
device ID by hand at developer.apple.com.

Developer Mode is a separate question and fails differently — at install rather
than at build. Check it with:

```sh
xcrun devicectl device info details --device <id> | grep -i "Developer Mode"
```

## Tests must not reach real services, and a default can hide that they do

Two separate versions of the same bug, both invisible to every gate.

**The suite played Zelda out loud.** `isMuted` is `@Published`, so assigning it
in `init` goes through the property wrapper's setter — and its `didSet` **fires
during initialisation**, where a plain stored property's would not. The observer
started the audio engine, so merely constructing an `EmulatorHost` opened the
audio device: twelve engine starts per test run, from tests that never call
`start()`.

**The suite read and wrote real iCloud data.** Save syncing defaulted to a live
`NSUbiquitousKeyValueStore`, and `FileManager.default.ubiquityIdentityToken` is
non-nil on a signed-in Mac.

Both are fixed the same way — the behaviour follows something intrinsic rather
than a default. Audio follows the *run state*, so a host nobody started cannot
make a sound. Syncing is opt-in, and `GameLauncher` is the single place that
asks for it. Neither needs test-runner detection, which is the tempting fix and
the fragile one.

## Measuring what is on screen

Two wrong conclusions were reported about the tvOS layout before one stuck: a
palette bug and a cropping bug. Neither existed.

- The "swapped red and blue" was a **mid-fade frame**. Zelda's attract sequence
  passes through a blue-black state that looks exactly like a channel swap.
  Capture again a few seconds later before concluding anything.
- The "cropping" came from measuring **non-black content** instead of the view's
  bounds. Zelda's frame is largely black, so measured extents move with whatever
  is on screen — and the diagnostics overlay attaches to the full-screen
  container rather than to the picture, which makes the picture look inset when
  it is not.

The only reliable measurement is to give the screen view a distinctive
background, screenshot, measure *that*, and revert. It gives 2720x2040 on a
3840x2160 Apple TV — exactly 4:3.

A physical Apple TV can be screenshotted:

```sh
xcrun devicectl device capture screenshot --device <id> --destination shot.png
```

## `gh api --jq` mangles multi-line bodies

Exporting the issue tracker reported **zero comments** twice, which looked
exactly like a repository with no comments.

`gh api --jq` emits raw newlines inside JSON strings, producing invalid JSON
that `jq` then refuses — and the failure surfaced as an empty result rather than
an error. Pipe the raw response through `jq` locally instead:

```sh
gh api repos/OWNER/REPO/issues/N/comments | jq '[.[] | {id, body}]'
```

## Branch protection cannot gate a single-author repository

`main` requires a pull request and one approving review. **GitHub does not allow
approving your own pull request**, and every PR here is authored by the same
account — so the requirement can never be satisfied normally and every merge is
an explicit `--admin` bypass.

The remaining protections do bite: required status checks, no force pushes, no
deletion. The approval rule is a speed bump rather than a gate, and is worth
either removing or backing with a separate identity for automation.
