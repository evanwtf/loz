# Decompilation

The goal is not an emulator. The goal is *The Legend of Zelda* as native Swift,
with no 6502 interpretation left.

## Why not static recompilation

Translating 6502 to ARM ahead-of-time sounds like the obvious route. It is not,
for three reasons:

1. **It does not remove the emulator.** It replaces the CPU interpreter — the
   easiest, most mechanical component. The PPU still has to be emulated
   cycle-accurately because game logic depends on NMI timing and sprite-0 hit.
2. **It buys nothing measurable.** The NES CPU runs at 1.79 MHz. Interpreting it
   costs roughly 1% of one modern core; the PPU costs 10–20%. Recompilation
   optimises the 1%.
3. **It cannot be done statically anyway.** MMC1 banking means an address does
   not identify code, and Zelda's RTS-based dispatch means branch targets are
   not statically resolvable. You end up needing a runtime dispatch table and an
   interpreter fallback — i.e. most of what you were trying to remove.

True decompilation — recovering the *logic* as readable Swift — is a different
and much larger undertaking, and the only one that actually ends with no
emulation.

## The strategy: incremental verified conversion

Big-bang rewrites of this kind fail. The approach that works, and that
comparable projects (SM64, Zelda 64) used, keeps the game playable at every
single step:

```
1. Emulator runs the ROM correctly            ← oracle established
2. Analyse the ROM to find routine boundaries
3. Decompile ONE routine to Swift
4. Differentially test it against the interpreter
5. Register it in the RoutineTable
6. Repeat
```

Unconverted routines keep running interpreted. Progress is measurable
(converted / discovered), correctness is mechanical rather than hoped for, and
there is never a period where nothing works.

## The two roles the emulator plays

### Oracle

For a candidate routine: snapshot state, run the interpreted 6502 to its `RTS`,
restore the snapshot, run the Swift version, then assert identical registers,
flags, RAM deltas, and ordered register writes.

Implemented as `RoutineVerifier` in `NESAnalysis`. Two things it must get right,
both of which were bugs on the first real run:

- **Step the CPU alone, not the machine.** Clocking the PPU lets an NMI fire
  mid-routine and run the game's entire frame handler — 13,792 writes against
  the native run's 3.
- **Force the routine's bank.** A restored save state carries whatever bank was
  live when captured, so without this, verification executes the wrong bytes
  entirely.

Ordered writes matter more than they look. The two pulse-channel loaders write
their register pair in opposite orders; transposing either leaves *identical
final memory* and only the ordered comparison catches it. There is a test that
feeds the verifier a transposed version and asserts rejection, plus one that
feeds it a wrong `resetAudio` — without those, a verifier that rubber-stamps
everything is indistinguishable from one that works.

### Discovery

This is the part that is easy to underestimate. Static analysis **plateaus**,
and worse, most of what it claims is not solid:

```
$ nesrun analyze zelda.nes
  Routines (JSR):       116
  Indirect JMPs:          5   <- need runtime dispatch

  Confident   (from vectors, fixed bank):   2187 bytes   1.7%
  Speculative (entry retried per bank):    32587 bytes  24.8%
```

Only **1.7% of the ROM** is confidently code. The rest comes from re-tracing
entry points against banks that may not contain them, which finds real code but
also decodes data as instructions. The five unresolved `JMP ($xxxx)` sites are
the main state-machine dispatchers, and **everything behind them is invisible**
to static analysis.

Execution resolves this exactly — a running CPU knows the live bank and the real
indirect target. So playing the game *is* the code discovery mechanism:

```sh
nesrun play zelda.nes --load-state overworld.state \
  --input "right:150,down:100" --trace
```

`NES.onInstruction` reports `(bank, PC)` per instruction; coverage is folded to
flat PRG offsets so it can be compared directly against the static map. Walking
into a dungeon reveals the dungeon code, with exact bank attribution.

Tracked in [#5](../../../issues/5).

## The dispatch mechanism

Already implemented and tested.

```swift
nes.nativeRoutines.register(
    bank: 0, address: 0x9000, name: "updateLinkPosition", cycles: 42
) { machine in
    // native Swift, reading and writing machine state
}
```

On each instruction, `NES.dispatchNativeRoutine` checks
`(mapper.currentPRGBank, cpu.pc)`. On a hit it runs the Swift body, performs an
`RTS`, and charges `cycles`.

Three details that are easy to get wrong:

- **Keys are bank-scoped.** `$8000` in bank 0 and bank 3 are different routines.
- **Cycles must be declared.** The PPU is clocked from CPU cycles; a routine
  that returned "instantly" would desynchronise the picture.
- **The table is empty by default.** An unmodified `NES` is a plain emulator,
  and `nativeRoutines.isEmpty` short-circuits the check entirely.

`nativeCallCounts` records how often each converted routine actually ran —
useful for confirming something is on the hot path before optimising it.

## Converted so far

| Routine | What it does |
|---|---|
| `00:9D42 resetAudio` | Order-sensitive `$4015` writes: silence all, then re-enable |
| `00:BF98 writeMapperRegister` | MMC1 serial 5-bit register protocol |
| `00:9BFF loadPulse1Registers` | Sweep then control |
| `00:9C1D loadPulse2Registers` | Control then sweep |
| `00:9EE2 lookupSoundTableEntry` | Masked index plus table base |

All verified across 48 randomised entry states, and observed executing during
real gameplay via `nesrun play --native`.

### Finding candidates

Leaf routines — no `JSR`, no `JMP` — are the place to start, and they fall out
of the disassembly directly:

```sh
nesrun disasm zelda.nes --bank 0 --out bank0.asm
# then filter routine bodies for ones containing neither JSR nor JMP
```

### Writing flag-exact Swift

The flags a routine leaves behind are part of its contract; callers branch on
them. Rather than re-deriving ADC's overflow rule by hand in every conversion,
`CPU6502` exposes the real operations:

```swift
cpu.addWithCarry(value)       // ADC, sets C V Z N
cpu.subtractWithCarry(value)  // SBC
cpu.compareValues(reg, value) // CMP/CPX/CPY
cpu.shiftLeft(value)          // ASL
cpu.shiftRight(value)         // LSR
cpu.setZeroNegative(value)
```

These are a stepping stone, not the destination. Once a routine's callers are
also native, the flags between them stop being observable and the code can be
raised to idiomatic Swift — with equivalence then checked at the boundary of the
converted region rather than routine by routine. That is how a decompilation
gradually stops looking like transliterated assembly.

## Order of work

1. ~~**Discovery** ([#5](../../../issues/5))~~ — done: 253 routines observed
2. ~~**Verification** ([#16](../../../issues/16))~~ — done: RoutineVerifier
3. **Symbols** ([#6](../../../issues/6)) — so code reads `linkPositionX`, not `ram[0x70]`
4. **Conversion** ([#7](../../../issues/7)) — bank 0 first; it is 79% code and holds the engine core
5. **Native rendering** ([#10](../../../issues/10)) — the last emulated component to go

Steps 1–3 are prerequisites. Attempting step 4 first means decompiling
unidentified routines with unnamed variables and no way to check the result.

## Scale, honestly

This is a long project. Comparable decompilation efforts took teams years; this
one is smaller but still substantial. The incremental approach means it delivers
a working, playable, progressively-more-native game the entire way through
rather than paying off only at the end — which is what makes it worth starting
at all.
