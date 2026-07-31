# Testing

107 tests across 8 suites, using swift-testing. `swift test` runs in ~0.07s, so
there is no excuse for not running it.

## Philosophy

The emulator is the oracle for every decompiled routine. A subtle bug here does
not stay here — it gets baked into "verified" native code and becomes far harder
to find later. So the CPU and PPU are tested against their documented semantics
rather than against "the game looks right".

That is not theoretical. The sprite off-by-one (see below) was invisible on
screen and would have been inherited by every conversion that depended on split
timing.

## Suites

| Suite | Guards |
|---|---|
| `OpcodeTableTests` | The 256-entry table has not shifted; spot-checks anchors |
| `CPUAddressingTests` | Zero-page wrapping, page-cross penalties, the `JMP (indirect)` bug |
| `CPUArithmeticTests` | ADC/SBC overflow in all four sign combinations, compares, shifts |
| `CPUControlFlowTests` | Branches, subroutine frames, interrupt push semantics |
| `PPUTests` | Register behaviour, loopy writes, mirroring, sprite-0 hit boundaries |
| `BusTests` | RAM/register mirroring, OAM DMA, controller ports |
| `ControllerTests` | Shift-register order, strobe, latch stability |
| `RoutineDispatchTests` | Native dispatch replaces interpretation transparently |

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

- **APU** — not implemented ([#4](../../../issues/4))
- **Cycle-exact interrupt hijacking** — interrupts are polled between
  instructions; no commercial game depends on finer granularity
- **MMC1 consecutive-write suppression** — see
  [emulator-mappers.md](emulator-mappers.md)
- **Visual regression** — planned against the overworld reference map
  ([#8](../../../issues/8))
- **End-to-end gameplay** — currently manual via `nesrun play`; the boot-to-
  overworld script in `docs/scripts/` is the seed for automating it
