# loz

An NES emulator written from scratch in Swift, being incrementally decompiled
into a native Swift port of *The Legend of Zelda*, to run on iPhone, Apple TV,
and macOS. Not for the App Store.

**One app = one game.** There is no ROM picker and no game library. The
emulation machinery is reusable libraries; each title is a small game target
plus a thin app target that embeds its own ROM.

## Status

The emulator runs the game. Verified end to end: boots, navigates the menus,
registers a save file, enters the overworld, and walks between screens with the
sprite-0-hit status bar split intact.

| Component | State |
|---|---|
| 6502 CPU | Complete, incl. undocumented opcodes |
| PPU | Background, sprites, scrolling, sprite-0 hit |
| MMC1 mapper | Complete (Zelda's SNROM board) |
| APU | Not started — the game is silent ([#4](../../issues/4)) |
| Agent harness | Scripted input, PNG capture, save states |
| App targets | Shell written, targets pending ([#1](../../issues/1)–[#3](../../issues/3)) |
| Decompilation | Dispatch mechanism in place; no routines converted yet |

107 tests.

## Layout

```
Sources/
  NESCore/     Emulator — ships inside every game app
  NESAnalysis/ Disassembler and static analysis — development only
  NESPlayer/   Reusable SwiftUI shell: screen, touch/keyboard/controller input
  ZeldaGame/   Zelda metadata, symbol map, decompiled routines
  nesrun/      CLI harness
Reference/     Overworld map (Rick N. Bruns, NESMaps.com)
docs/          Harness guide and input scripts
```

Adding Super Mario Bros. 3 means a new `SMB3Game` target and an MMC3 mapper
([#11](../../issues/11)) — not a fork of any of this.

## Target cartridge

The retail Zelda cartridge (SNROM board) reports:

| Field | Value |
|---|---|
| PRG-ROM | 128 KB (8 × 16 KB) |
| CHR | 8 KB CHR-**RAM** (no CHR-ROM banks) |
| Mapper | 1 (MMC1) |
| Mirroring | Horizontal (mapper-controlled) |
| Battery | Yes — 8 KB WRAM at `$6000`, persisted as a `.sav` |

## ROMs

No ROM is included or committed; `.nes` files and `.state` snapshots are
gitignored. Supply your own dump of a cartridge you own. Each `GameDefinition`
pins an expected SHA-256, so a different dump fails loudly rather than
producing subtle nonsense.

## Building

```sh
swift build
swift test

nesrun info    zelda.nes                       # cartridge geometry
nesrun analyze zelda.nes                       # static code/data analysis
nesrun disasm  zelda.nes --bank 0 --out b0.asm # annotated listing
nesrun play    zelda.nes --input "wait:60,start:4" --out shot.png
```

See [docs/agent-harness.md](docs/agent-harness.md) for the play harness,
including the menu-navigation notes and the boot-to-overworld script.

## Approach

The emulator is not the destination — it is the scaffolding. Decompilation
proceeds incrementally, and the emulator serves as both the **oracle** (native
routines are differentially tested against the interpreted 6502) and the
**discovery mechanism** (static analysis stalls at Zelda's indirect dispatchers;
execution traces resolve them). The game stays playable at every step.
