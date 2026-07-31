# Architecture

## The shape of the thing

Two constraints drive the entire design:

1. **One app = one game.** No ROM picker, no library UI. The app icon launches
   Zelda. From the outside it is a game, not an emulator.
2. **A second game must not require a fork.** Super Mario Bros. 3 should be a
   new game target plus a mapper, sharing everything else.

Those pull in opposite directions — the first wants a bespoke app, the second
wants generality — and the resolution is to put all generality in libraries and
leave each app target as a thin shell.

```
┌─────────────────┐  ┌─────────────────┐
│  ZeldaiOS.app   │  │   SMB3iOS.app   │   thin: @main, Info.plist, ROM
└────────┬────────┘  └────────┬────────┘
         │                    │
    ┌────▼────────┐      ┌────▼────────┐
    │ ZeldaGame   │      │  SMB3Game   │   game-specific: metadata,
    └────┬────────┘      └────┬────────┘   symbols, decompiled routines
         │                    │
         └────────┬───────────┘
                  │
        ┌─────────▼─────────┐
        │     NESPlayer     │   reusable UI shell
        └─────────┬─────────┘
                  │
        ┌─────────▼─────────┐
        │      NESCore      │   the machine
        └───────────────────┘

        ┌───────────────────┐
        │    NESAnalysis    │   dev-only, never ships
        └───────────────────┘
```

## Targets

### `NESCore`

The console. CPU, PPU, cartridge, mappers, controllers, save states, and the
native-routine dispatcher. No UI, no Foundation-heavy dependencies, no
game-specific knowledge. This is the only target that ends up in a shipping app
alongside the game library and the shell.

Key types:

| Type | Role |
|---|---|
| `NES` | The machine, and the CPU's bus. Owns address decoding. |
| `CPU6502` | Interpreter. Also the correctness oracle for decompiled code. |
| `PPU` | Dot-based renderer producing a 256×240 RGBA framebuffer. |
| `Mapper` | Protocol; `NROM` and `MMC1` implement it. |
| `Cartridge` | Parsed iNES image plus CHR-RAM and battery-backed WRAM. |
| `GameDefinition` | What an app needs to present exactly one game. |
| `RoutineTable` | Maps `(bank, address)` to native Swift implementations. |
| `SaveState` | Full machine snapshot. |

### `NESAnalysis`

Disassembler and static analyzer. Deliberately a separate target so the
shipping binary never contains a disassembler. Depends on `NESCore` for the
shared opcode table.

### `NESPlayer`

Reusable SwiftUI shell, parameterised by a `GameDefinition`: framebuffer
display, on-screen touch controls, keyboard, and MFi/Xbox/DualSense support.
Knows nothing about any specific game.

### `ZeldaGame`

Everything specific to this cartridge: expected ROM hash, symbol map, and — as
the project progresses — decompiled routines.

### `nesrun`

CLI harness. Cartridge inspection, static analysis, disassembly, and the
agent-drivable play mode.

## Clocking

The CPU drives everything. `NES.step()` runs one instruction, then runs the PPU
for three dots per CPU cycle:

```swift
let cpuCycles = dispatchNativeRoutine() ?? cpu.step()
for _ in 0..<(cpuCycles * 3) {
    ppu.step()
    if ppu.nmiRequested { cpu.triggerNMI() }
}
cpu.setIRQLine(mapper.irqAsserted)
```

This has a consequence that matters for decompilation: **a natively-executed
routine must still declare its cycle cost.** If native code returned
"instantly", the PPU would fall behind and the picture would break. Hence
`NativeRoutine.cycles`.

## The shared opcode table

`Opcodes.table` is a single 256-entry table consumed by both the interpreter and
the disassembler. Writing it once means the two can never disagree about what a
byte means — which matters, because the disassembler's output is the input to
hand-written decompiled code.

## Address decoding

`NES` implements `CPUBus` and owns the whole map:

| Range | Destination |
|---|---|
| `$0000-$1FFF` | 2 KB internal RAM, mirrored ×4 |
| `$2000-$3FFF` | 8 PPU registers, mirrored every 8 bytes |
| `$4014` | OAM DMA (stalls the CPU 513–514 cycles) |
| `$4016` | Controller strobe (write) / pad 1 (read) |
| `$4017` | Pad 2 (read) / APU frame counter (write) |
| `$4000-$4017` | APU — not yet implemented |
| `$4020-$FFFF` | Cartridge, via the mapper |

The PPU has its own separate address space, decoded in `PPU.ppuRead/ppuWrite`.

## Where the emulator fits in the larger goal

The emulator is scaffolding, not the destination. It plays two roles that make
decompilation possible at all:

- **Oracle.** Native routines are differentially tested against the interpreted
  6502, so every conversion is mechanically proven rather than hoped.
- **Discovery.** Static analysis cannot see past Zelda's indirect dispatchers.
  Execution can. Playing the game reveals code.

See [decompilation.md](decompilation.md).
