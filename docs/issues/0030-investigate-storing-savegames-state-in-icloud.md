# #30 — Investigate storing savegames/state in iCloud

| | |
|---|---|
| **State** | implemented |
| **Labels** | — |
| **Opened** | 2026-08-02 |
| **Closed** | — |
| **Author** | evandhoffman |

---

Maybe this would allow sharing a game between iPhone and appletv?


---

## Comments (1)

### evandhoffman — 2026-08-02

Investigated. **Yes, this would work — and for tvOS it is closer to a requirement than a convenience.** But there are two different things to sync with different answers, and one hard prerequisite.

## What there is to sync

| | What it is | Size | Where now |
|---|---|---|---|
| `<game>.sav` | Cartridge battery RAM — the game's own three quest slots | **8 KB** (`prgRAM`, `$6000-$7FFF`) | `EmulatorHost.defaultSaveURL`, Application Support |
| `slotN.state` ×4 | Full machine snapshots | **~61 KB each** | `SaveStateStore` |
| `<game>.autoresume` | Same, written on backgrounding | ~61 KB | `AutoResume.url(for:)` |

The `.sav` is the one that answers your actual question. "Sharing a game between iPhone and Apple TV" means carrying quest progress — which dungeons are done, what's in the inventory — and that is entirely the 8 KB battery file. Snapshots are a different feature: a mid-fight moment, which is useful on a phone during a commute and slightly odd to resume on a television.

## tvOS turns this from nice-to-have into a dependency

This is the part worth knowing before scheduling it. **tvOS gives apps no guaranteed persistent local storage** — the Documents directory can be purged whenever the system wants space, and Apple's guidance is that tvOS apps keep persistent state in iCloud (key-value store or CloudKit) rather than on device.

So #2 (the tvOS target) does not really work without this. As written today, the tvOS build would appear to save and then silently lose progress at an arbitrary later date, which is worse than not saving. **I'd make #30 a blocker on #2** rather than a parallel enhancement.

## Recommendation

**`NSUbiquitousKeyValueStore` for the `.sav`, and leave snapshots local — at least at first.**

- 8 KB against a 1 MB total budget is nothing, and KVS is the one mechanism that works the same on iOS, macOS and tvOS with no file coordination.
- All five snapshots would be ~305 KB, which *fits* in KVS but is exactly the blob-shaped use Apple tells you not to put there. If they should sync later, that is an iCloud Documents (ubiquity container) job — and `SaveStateStore` is already built around a `directory`, so it is a one-line change of URL plus conflict handling.
- Conflict semantics need a decision either way. Last-writer-wins on an 8 KB blob means that if the TV and the phone are both played before a sync, one session's progress vanishes. Syncing on foreground/background transitions and keeping the local file as a backup covers the realistic case (one person alternating devices) without pretending to solve the general one.

The seams already exist: `EmulatorHost` takes a `saveURL` and `SaveStateStore` takes a directory, so this wants a small `SaveSyncing` abstraction with a local implementation and an iCloud one, not surgery.

## The prerequisite

**iCloud entitlements require a paid Apple Developer Program membership.** A free Apple ID cannot enable the iCloud capability at all — and `distribution.md` documents both paths, with `Apps/ZeldaiOS.xcodeproj` currently carrying automatic signing and no entitlements file.

So before any of this gets built: are you on the paid program? If not, this is blocked on that rather than on any code, and the tvOS storage problem needs a different answer.

## One note on content

A `.state` snapshot embeds CHR-RAM, which is cartridge data. Putting it in the user's own iCloud account is not distribution and does not implicate anything in `LICENSE` — but it is another reason to prefer syncing the `.sav`, which is purely the player's own progress, over the snapshots, which are partly the game.


---

## Resolution

Implemented. Cartridge battery saves sync through `NSUbiquitousKeyValueStore`.

**What syncs:** the `.sav` only — 8 KB of `prgRAM`, which *is* the quest
progress (three slots, inventory, dungeons cleared). Snapshots stay local: at
~61 KB each they are blob-shaped for a key-value store, and a mid-fight moment
from a phone is an odd thing to resume on a television.

**Why key-value and not CloudKit or a document container:** 8 KB against a 1 MB
budget, identical API on iOS, macOS and tvOS, and no file coordination to get
wrong.

**The identifier is pinned, not derived.** The entitlement names
`$(TeamIdentifierPrefix)wtf.evan.loz.zelda` on *both* targets rather than
`$(CFBundleIdentifier)`. The Apple TV bundle is `wtf.evan.loz.zelda.tv`, so
deriving it would have given the two apps separate stores — they would have
synced perfectly and never seen each other, which is the entire point.

**Conflict rules.** Newer wins, with two exceptions, because the cost of being
wrong is one-sided — a needless local save costs nothing and a needless
overwrite costs a quest:

- An all-zero save never beats a non-empty one however new it looks. That is
  what a cartridge reads as before anyone has played, so a freshly installed
  device would otherwise push "no progress" over a finished game on launch.
- A wrong-sized payload is refused outright rather than handed to the emulator.

There is also a five-second clock tolerance: without one, two devices whose
clocks differ by a second trade the save back and forth on every launch.

**Degrades quietly.** No iCloud account or no entitlement means local-only
saves, not an error the player can do anything about.

Verified on device: the entitlement signs in as
`94S5PZTVPY.wtf.evan.loz.zelda`. 14 tests cover the resolution rules through a
fake store, so they need no account, entitlement or network.

Unblocks [#2](0002-tvos-app-target-for-apple-tv.md) — tvOS gives an app no
guaranteed persistent local storage, so a quest kept only in its Documents
directory can be evicted whenever the system wants space.
