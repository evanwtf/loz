# Saves and iCloud sync

How a quest survives closing the app, and how it follows you to another device.

This is cross-platform on purpose. Saving is the one subsystem where the three
targets genuinely differ — an Apple TV has no guaranteed persistent storage at
all — and the bugs that mattered were all found on the platform whose
documentation nobody reads first. [ios-app.md](ios-app.md) covers what the
player *sees* (the notices, the loading screen, the copy); this covers what the
code does.

## Three mechanisms, three jobs

| | What it is | Size | Syncs? |
|---|---|---|---|
| **Battery save** (`zelda.sav`) | The cartridge's own SRAM at `$6000` — the game's own save files, the three quest slots | 8 KB | **Yes**, on every change |
| **Save states** (4 slots) | Full machine snapshots the player chooses to keep, with thumbnails | ~61 KB each | No |
| **Auto-resume** | One automatic snapshot so the app reopens where it left off | 61 KB → **13 KB** zlib | **Yes**, on background only |

Save states deliberately do not sync. They are a debugging and
convenience feature tied to one device's session, four of them would be 244 KB
against a 1 MB budget, and nobody expects slot 3 on the phone to be slot 3 on
the TV. The battery save is the one that *is* the quest.

## What syncs, and when

Both synced items use `NSUbiquitousKeyValueStore` under keys `battery-save` and
`auto-resume`.

**Why the key-value store** rather than CloudKit or an iCloud Documents
container: the thing worth syncing is small and identical everywhere. 8 KB
against a 1 MB budget, the same API on iOS, macOS and tvOS, and no file
coordination to get wrong.

| Event | Local file | iCloud |
|---|---|---|
| Battery RAM changed (checked ~3 s) | write | push |
| Battery RAM unchanged | — | — |
| Auto-resume timer (20 s) | write | — |
| Scene becomes `.inactive` | write | — |
| Scene becomes `.background` | write | push |

Two of those rows are load-bearing.

**Unchanged battery RAM writes nothing.** The three-second timer used to write
8 KB and push 8 KB every tick regardless. That is a needless write every three
seconds forever, into a budget shared with every other key, from a service that
throttles frequent writers — and it made "saved" an event with no meaning,
because it happened constantly. Comparing first costs nothing next to what it
avoids.

**`.inactive` writes but does not push.** tvOS asks for an app-switcher
thumbnail several times a minute and each request drives scene phase to
`.inactive`. Pushing there sent 13 KB to iCloud every time the system took a
picture of the screen. Only `.background` means the app is actually leaving.

## Not every byte of PRG-RAM is a save

Zelda uses its cartridge RAM as scratch, not only for the quest. Comparing all
8 KB made walking through a door indistinguishable from choosing Save — the
"Game saved" notice fired on every screen transition.

`GameDefinition.volatilePRGRAM` declares the ranges to ignore. For Zelda that
is `0x0536..<0x07EA`, found by diffing PRG-RAM across a screen change that
involved no save. The default is `[]`, so a game that has not been measured
simply compares everything and behaves as before.

This is why the notice lands on moments that feel like saving — choosing Save,
dying and continuing, registering a name — rather than constantly.

## Where files actually go

`SaveLocation` picks the writable root, and the platform split is not a
preference:

```swift
#if os(tvOS)
    let candidates: [FileManager.SearchPathDirectory] = [.cachesDirectory]
#else
    let candidates: [FileManager.SearchPathDirectory] =
        [.applicationSupportDirectory, .cachesDirectory]
#endif
```

**`.applicationSupportDirectory` cannot be created on tvOS.** Not "is empty" —
it cannot be created, and every call site swallowed the failure with `try?`.

tvOS gives an app no guaranteed persistent storage. Caches is what there is and
the system may evict it. That is the platform's model rather than a workaround,
and it is precisely why the battery save syncs: **Caches plus iCloud is the
durable pair; Caches alone is a cache.**

A nil URL must therefore mean "keep going without a file", never "stop". On
tvOS the cloud copy is the real store.

## Which copy wins

`SaveSync.resolve(local:remote:expectedSize:)`. Newer normally wins, with three
exceptions, all of which exist because **the cost of being wrong is entirely
one-sided** — a needless local save costs nothing, a needless overwrite costs
somebody's quest.

| Rule | Why |
|---|---|
| A wrong-sized payload is refused outright | It cannot be from this cartridge, and handing the emulator a PRG-RAM image that does not fit is worse than ignoring it |
| An **all-zero save never beats a non-empty one**, however new it looks | That is exactly what a cartridge reads as before anyone has played, so a freshly installed device would otherwise push "no progress" over a finished game the moment it launched |
| The remote must be newer by more than **5 seconds** (`clockTolerance`) | Device clocks are not identical and iCloud promises no ordering. Without a tolerance, two devices a second apart trade the save back and forth on every launch, each convinced it is newer |

Identical data resolves to `.noChange` before any of this, so agreement is
never mistaken for a conflict.

## Knowing whether it worked

`NSUbiquitousKeyValueStore` reads from a **local cache**, delivers remote
changes asynchronously, and never confirms delivery. From outside the app, a
device with no iCloud account and a perfectly-syncing device that happens to
hold nothing look identical: both just carry on with the local file.

Silent degradation is the correct *behaviour* — nobody should lose a game
because they signed out — but it leaves "is syncing actually working?" with no
answer short of buying a second device. Three things answer it instead.

**`SaveSync.CloudStatus`** names the four states: `off` (this build never asked
to sync), `unavailable` (no account, or signed without the entitlement), `empty`
(reachable, holding nothing), `present` (reachable, holding a save).

**`CloudGate`** waits at launch for a delivery rather than starting a quest from
an empty cache. It **polls** rather than observing
`didChangeExternallyNotification` — the notification could arrive before the
observer attached, a race with no fix from the observing side.

**The diagnostics overlay** carries two counters:

```
save 2@14s  sync 2@14s handed
```

Two, not one, because a save and its push fail independently. `save 2 sync 0`
is a device that never pushed; a device that pushed and was later overwritten is
a completely different bug. One "last saved" reading cannot separate them. The
line turns yellow when saves outrun syncs.

That the overlay exists at all is a consequence of the log being unreachable on
the device that needed it — see [Diagnosing this on an Apple TV](#diagnosing-this-on-an-apple-tv).

## Availability must not be `ubiquityIdentityToken`

`UbiquitousKeyValueStore.isAvailable` latches on `store.synchronize()`, which
returns false when the app was built without a valid `ubiquity-kvstore-identifier`
entitlement. It is the only signal the key-value store gives about itself.

**It must not be `FileManager.ubiquityIdentityToken`.** That token describes the
user's *iCloud Drive* identity, and **tvOS has no iCloud Drive** — so it is nil
on an Apple TV no matter how correctly the app is signed. Because that property
gated reads *and* writes, the Apple TV never read or wrote a byte while the
iPhone synced perfectly. The platform that most needs syncing was the one
silently excluded from it.

Availability is latched because it can only improve — an account signs in, the
daemon comes up — so a `false` is re-probed while a `true` is kept.

## The entitlement is pinned, not derived

Both targets name **the phone's** bundle identifier:

```xml
<key>com.apple.developer.ubiquity-kvstore-identifier</key>
<string>$(TeamIdentifierPrefix)wtf.evan.loz.zelda</string>
```

The Apple TV bundle is `wtf.evan.loz.zelda.tv`, so deriving this from
`$(CFBundleIdentifier)` would give the two apps separate stores — each syncing
perfectly with itself and never seeing the other, which is the entire point.

**Xcode's capability editor rewrites these files** and will re-add
`aps-environment` and CloudKit keys. Neither is used. Both `Zelda.entitlements`
files carry a comment saying so, because the setting looks like a mistake
unless you know why it is there. See
[gotchas.md](gotchas.md#xcode-rewrites-entitlements-files).

## Diagnosing this on an Apple TV

The unified log is unavailable on exactly the device that needs it. `log
collect` from a network-paired Apple TV wants root and then fails with **"Device
not configured"**; `log stream` has no device flag any more; devicectl has no
console.

So the diagnosis came off the screen. The iCloud loading screen showed a cloud
save timestamp **frozen at 6:11 PM across three hours and several saves** —
which says the device is not writing, though not why. The overlay counters said
`save 0@- sync 0@- never`, which says the save path never ran at all.

That is the general lesson and it is why the frame timings are drawn on screen
too: **an instrument you cannot read on the failing device is not an
instrument.**

### Three stacked bugs, none of them iCloud

Worth recording together, because each alone would have been enough and the
symptom pointed at the wrong subsystem all three times:

1. **Nowhere to write.** `.applicationSupportDirectory` cannot be created on
   tvOS, so `saveURL` was nil and every write returned at its first guard.
   Battery save, auto-resume and all four slots had silently done nothing for
   the entire life of the app.
2. **No local file also meant no cloud push.** One `guard` covered both, so the
   one platform whose *reason* for syncing is that it has no guaranteed local
   storage was the one platform locked out of it.
3. **Every screen transition looked like a save**, because all 8 KB were
   compared. See [Not every byte of PRG-RAM is a save](#not-every-byte-of-prg-ram-is-a-save).

It presented as an iCloud problem throughout. The TV read the cloud copy
correctly at every launch and never wrote one, so a quest saved on the TV
vanished and a quest from another device reappeared in its place — which looks
exactly like "iCloud is overwriting my save."

## The components

| Type | Job |
|---|---|
| `SaveLocation` | Where this platform lets the app keep files |
| `SaveSync` | Read/write one blob through a store; decide which copy wins |
| `KeyValueStore` | Protocol over the store, so resolution is testable without an account |
| `UbiquitousKeyValueStore` | The real `NSUbiquitousKeyValueStore` |
| `SnapshotCodec` | zlib for the resume snapshot — 61 KB is mostly RAM and compresses to 13 KB |
| `CloudGate` | Wait at launch for a delivery; produce a `SaveReport` |
| `SaveReport` | One of seven player-facing states, with timestamp and relative age |
| `SaveNotice` / `SaveNoticeStream` | The in-game "Game saved" capsule |
| `AutoResume` | The 20-second snapshot and its lifecycle |
| `SaveStateStore` | The four manual slots |

`KeyValueStore` is a protocol for one reason: the genuinely risky part of this
feature is the resolution logic, and CI has no iCloud account, no entitlement
and no network. Without the abstraction the merge rules would be the only
untested code in the subsystem.

## Tests

Twelve suites, 73 tests, all runnable with no ROM and no account:

| Suite | Guards |
|---|---|
| `Save sync resolution` | Which copy of a quest wins when two devices disagree |
| `Save sync store` | Round trip, empty and corrupt stores, unavailable iCloud |
| `Cloud status` | The four states are distinguished correctly |
| `Snapshot sync` | The resume snapshot round-trips through the store |
| `Snapshot resolution by time` | Newer snapshot wins, within tolerance |
| `Cloud gate` | Waiting, delivery, timeout, and unavailable |
| `iCloud loading screen copy` | Every state says something true and actionable |
| `iCloud save timestamp` | Every time zone labels itself |
| `Battery save notices` | The right notice for the right outcome |
| `Scratch writes are not saves` | `volatilePRGRAM` suppresses screen-transition noise |
| `Syncing without local storage` | The tvOS case: push works with no writable file |
| `Auto-resume` | Snapshots round-trip; foreign and corrupt ones are refused |

`Syncing without local storage` is the direct regression guard for bug 2 above,
and `Scratch writes are not saves` for bug 3. Bug 1 is guarded by
`SaveLocation` having no way to express the old behaviour.

## Deliberately not done

- **Save states do not sync.** Size, and nobody expects slot 3 to be shared.
- **No conflict UI.** The rules above resolve every case without asking. A
  prompt would appear at launch, before the player knows which save is which.
- **No CloudKit.** 8 KB does not need a database, a schema, or a container.
- **No delivery confirmation**, because the API offers none. `sync … handed`
  in the overlay means handed to the daemon, and the wording is deliberate.
