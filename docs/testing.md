# Testing

261 tests across 28 suites, using swift-testing. `swift test` runs in ~10s —
most of which is the four `Host input path` and seven `Auto-resume` tests
sharing a ten-second budget — so there is no excuse for not running it.

## Philosophy

The emulator is the oracle for every decompiled routine. A subtle bug here does
not stay here — it gets baked into "verified" native code and becomes far harder
to find later. So the CPU and PPU are tested against their documented semantics
rather than against "the game looks right".

That is not theoretical. The sprite off-by-one (see below) was invisible on
screen and would have been inherited by every conversion that depended on split
timing.

## Suites

Twenty-eight suites across twenty-three files — `APUTests.swift` declares three.

### `NESCoreTests` — the emulator (156)

| Suite | Tests | Guards |
|---|---|---|
| `Opcode table` | 4 | The 256-entry table has not shifted; spot-checks anchors |
| `CPU: addressing modes` | 14 | Zero-page wrapping, page-cross penalties, the `JMP (indirect)` bug |
| `CPU: arithmetic and flags` | 25 | ADC/SBC overflow in all four sign combinations, compares, shifts |
| `CPU: control flow, stack, interrupts` | 22 | Branches, subroutine frames, interrupt push semantics |
| `PPU` | 20 | Register behaviour, loopy writes, mirroring, sprite-0 hit boundaries |
| `System bus` | 11 | RAM/register mirroring, OAM DMA, controller ports |
| `Controller` | 5 | Shift-register order, strobe, latch stability |
| `APU components` | 15 | Envelope, sweep, length counter, frame sequencer |
| `APU channels` | 8 | Pulse, triangle, noise, DMC period and output |
| `APU integration` | 7 | Mixing, DC blocking, the sample buffer |
| `Save states` | 6 | Round-trip fidelity; restored machines stay in lockstep |
| `Native routine dispatch` | 6 | Native dispatch replaces interpretation transparently |
| `Nametable reading` | 7 | Tile reads honour mirroring; the active table follows control |
| `CPU: shift and rotate helpers` | 6 | The helpers routines are built from agree with the interpreter |

### `NESAnalysisTests` — the dev-only tooling (29)

| Suite | Tests | Guards |
|---|---|---|
| `OAM entity reading` | 10 | Sprite decode, clustering into actors, item vs enemy |
| `Room clear monitor` | 6 | When "the room is empty" may be believed |
| `Tile grid pathfinding` | 9 | A* routes round walls, and reports no route rather than a bad one |
| `Route to input script` | 4 | A route becomes the same script syntax `play` already takes |

Every case in that suite is a mistake the harness actually made. Reading OAM
looks trivial and is not: status bar sprites became phantom targets, and a
dropped key classified as an enemy cost 552 sword swings against an item that
only had to be walked onto.

### `NESPlayerTests` — the app shell (42)

| Suite | Tests | Guards |
|---|---|---|
| `On-screen control layout` | 13 | Controls fit the screen in **both** orientations; d-pad hit regions |
| `Auto-resume` | 7 | Snapshots round-trip; foreign and corrupt ones are refused |
| `Host input path` | 4 | A button pressed through `EmulatorHost` reaches the game |
| `Silent when headless` | 4 | A host nobody started never opens the audio device |
| `Save sync resolution` | 10 | Which copy of a quest wins when two devices disagree |
| `Save sync store` | 4 | Round trip, empty and corrupt stores, unavailable iCloud |

`Silent when headless` is a regression guard with an audible failure mode. Until
it existed, running `swift test` played Zelda through the speakers — eleven
`EmulatorHost` instances, twelve audio-engine starts — and so did `zeldamac
--selftest`. The cause is a Swift subtlety worth knowing: `isMuted` is
`@Published`, so assigning it in `init` goes through the property wrapper's
setter and its `didSet` **does** fire during initialisation, where a plain
stored property's would not. The observer started the engine on any unmuted
assignment, so merely constructing a host opened the audio device.

Audio now follows the *run state* rather than the mute flag alone: nothing that
never calls `start()` can make a sound, which needs no test-runner detection.
The APU still runs and still produces samples — `--selftest` continues to check
that it generated 99.8% of the expected count — only the speaker is gated.

`Host input path` exists because every layer below it can be correct while the
app is still unplayable. It drives the committed boot script through the host
exactly as `nesrun` does, then asserts that holding a direction actually moves
Link — the same claim a player makes when they say the controls do not work.
What it cannot cover is anything above `setButton`: the input faults that
actually shipped were in touch delivery and view invalidation, and were caught
by on-screen instrumentation rather than by this suite. See
[ios-app.md](ios-app.md#writing-a-diagnostic-that-can-be-trusted).

### `ZeldaGameTests` — the decompilation (35)

| Suite | Tests | Guards |
|---|---|---|
| `Decompiled routine equivalence` | 12 | Each native routine matches the 6502 original — registers, ordered writes, **and cycles** |
| `Zelda enemy slots` | 9 | Which object slots hold killable enemies, and which do not |
| `Zelda playfield` | 11 | Grid geometry against measured positions; the doorway rule |
| `Zelda symbol map` | 3 | Every recovered symbol is present under its measured address |

These twelve are the only tests that need `zelda.nes`. They skip cleanly when it
is absent, which is why CI passes on a clean checkout.

## Two bugs the tests caught

### Sprite vertical off-by-one

OAM stores Y minus one, so a sprite at `Y` occupies scanlines `Y+1 … Y+8`.
`evaluateSprites` computed the row as `scanline - Y`, drawing every sprite one
pixel too high and firing sprite-0 hit a scanline early.

A one-pixel offset is invisible by eye. `sprite0StartsOneScanlineBelowOAMY`
caught it immediately by asserting the flag must *not* be set on the scanline
matching the OAM Y.

### A fixture that could not fail correctly

The first NMI test asserted `stack(2) == high byte`, but `push16` writes the
high byte first, so reading upward from SP gives `[status, PC-low, PC-high]`.
The JSR test "passed" only because both bytes of `$0202` happen to be `0x02` —
it could never have caught the same mistake.

Fixed at the cause rather than the symptom: the fixture now exposes
`pushedPC`, `pushedStatus`, and `pushedReturnAddress`, so tests cannot express
the byte order wrongly.

## Writing tests

### Synthetic cartridges

Tests never need a real ROM — they build iNES images in memory. This keeps CI
possible without redistributing anything:

```swift
var header: [UInt8] = Array("NES\u{1A}".utf8)
header += [2, 1, 0x00, 0x00]              // 32KB PRG, 8KB CHR, mapper 0
header += [UInt8](repeating: 0, count: 8)
var prg = [UInt8](repeating: 0xEA, count: 0x8000)   // NOP fill
prg[0x7FFC] = 0x00; prg[0x7FFD] = 0x80              // reset vector -> $8000
```

### CPU fixture

`CPUFixture` loads a program into a flat 64 KB bus with reset already applied:

```swift
let f = CPUFixture([0xA9, 0xFF])   // LDA #$FF
f.step()
#expect(f.cpu.a == 0xFF)
#expect(f.negative)
```

Flag accessors are named after the datasheet (`carry`, `zero`, `overflow`, …) so
assertions read like the reference.

### Cycle counts

`step()` returns cycles, which is how timing is asserted:

```swift
let cross = CPUFixture([0xBD, 0xF0, 0x12])   // LDA $12F0,X
cross.cpu.x = 0x20                            // crosses into $1310
#expect(cross.step() == 5)                    // 4 base + 1 penalty
```

### PPU scenes

`PPUTests` builds scenes from CHR-RAM cartridges so pattern data can be written
directly, then runs the PPU to a target scanline and inspects flags.

## What is not covered

- **Cycle-exact interrupt hijacking** — interrupts are polled between
  instructions; no commercial game depends on finer granularity
- **MMC1 consecutive-write suppression** — see
  [emulator-mappers.md](emulator-mappers.md)
- **Visual regression** — implemented as `nesrun mapcheck`, which correlates
  rendered screens against the overworld reference map, but it needs the ROM so
  it cannot run in CI. Run it by hand after touching the PPU.
- **End-to-end gameplay** — driven by `nesrun play`/`navigate`/`probe` rather
  than by the suite, for the same reason: it needs the ROM.
- **The rendered image itself** — `PPUTests` asserts register and timing
  behaviour, not pixels. `mapcheck` is what covers the picture.
