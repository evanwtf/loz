# #36 — RoutineTable can't express a routine whose cycle count varies

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, decompilation |
| **Opened** | 2026-08-02 |
| **Closed** | 2026-08-02 |
| **Author** | evandhoffman |

---

Found while converting the three branch-free leaves in #7 (PR #35).

`NativeRoutine` carries a single fixed `cycles`, charged unconditionally by `NES.dispatchNativeRoutine`:

```swift
routine.body(self)
cpu.returnFromSubroutine()
cpu.advanceCycles(routine.cycles)
```

That is fine for straight-line code and wrong for anything with a branch, because the two paths cost different amounts. `00:9C09` is the clearest example:

```
9C09  A8        TAY
9C0A  B9 01 9F  LDA $9F01,Y
9C0D  F0 0D     BEQ $9C1C     ; table entry zero -> skip everything
9C0F  85 6A     STA $6A
9C11  8D 02 40  STA $4002
9C14  B9 00 9F  LDA $9F00,Y
9C17  09 08     ORA #$08
9C19  8D 03 40  STA $4003
9C1C  60        RTS
```

**31 cycles** when the entry is non-zero, **15** when it is zero. Any single declared number is wrong roughly half the time.

## Why it matters more than it looks

The PPU is clocked from the CPU's cycle count, so a routine that lies about its timing shifts the picture. And AGENTS.md requires "an honest cycle count" as part of a routine being done — right now that requirement simply cannot be met for a branching routine, so the honest move is to not convert one.

That is the blocker: **bank 0 is 79% code and most of it branches.** Of the 18 JSR targets in bank 0, only a handful are straight-line, and #35 took three of them. Continuing #7 past the leaves needs this first.

Note the differential verifier would *not* catch a wrong count — `RoutineVerifier` compares registers, flags and ordered writes, not elapsed cycles. So this fails silently as drift rather than loudly as a test failure.

## Work

- Let a routine report the cycles it actually consumed, rather than declaring one number up front. Simplest shape: the body returns `Int`, and `cycles` stays as documentation/metadata or is dropped.
- Update the eight existing routines to return their (now constant) counts.
- Add a test that a branching routine is charged differently on each path — and ideally extend `RoutineVerifier` to compare cycle counts against the interpreter, which would have caught this class of bug from the start.

## Related

- #7 — the epic this unblocks
- PR #35 also corrected three declared counts that were simply wrong (`resetAudio` 20 → 22, `writeMapperControl` 30 → 34, `lookupSoundTableEntry` 19 → 20), which is a hint that hand-declared numbers want checking by machine.
