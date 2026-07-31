# loz

An NES emulator written from scratch in Swift, being incrementally decompiled
into a native Swift port of *The Legend of Zelda*, to run on iPhone, Apple TV,
and macOS. Not for the App Store.

**One app = one game.** There is no ROM picker and no game library. The
emulation machinery is reusable libraries; each title is a small game target
plus a thin app target that embeds its own ROM.

## Status

The game is playable end to end: boots, navigates menus, registers a save file,
explores the overworld, crosses the bridge to Level 1, and plays through the
dungeon — with sound.

| Component | State |
|---|---|
| 6502 CPU | Complete, incl. undocumented opcodes |
| PPU | Background, sprites, scrolling, sprite-0 hit |
| APU | All five channels, playing through AVAudioEngine |
| MMC1 mapper | Complete (Zelda's SNROM board) |
| iOS app | Running, portrait and landscape, save states |
| macOS app | Running (`swift run zeldamac`) |
| tvOS app | Written, **unverified** — tvOS SDK not installed |
| Agent harness | Scripted input, PNG capture, snapshots, pathfinding, tracing |
| Decompilation | 5 routines native and verified; the loop is proven |

150 tests. CI green on a self-hosted macOS runner.

## Layout

```
Sources/
  NESCore/     Emulator — ships inside every game app
  NESAnalysis/ Disassembler, execution tracing, routine verifier (dev only)
  NESPlayer/   Reusable SwiftUI shell: screen, touch/keyboard/controller input
  ZeldaGame/   Zelda metadata, symbol map, decompiled routines
  nesrun/      CLI harness
  zeldamac/    macOS app, runs straight from SwiftPM
Apps/          iOS and tvOS app targets
Reference/     Overworld map (Rick N. Bruns, NESMaps.com)
docs/          Architecture, internals, harness guide
```

Adding Super Mario Bros. 3 means a new `SMB3Game` target and an MMC3 mapper
([#11](../../issues/11)) — not a fork of any of this.

## Quick start

```sh
swift build && swift test

# Play on macOS
swift run -c release zeldamac zelda.nes

# Drive it headlessly
swift run -c release nesrun play zelda.nes --input "wait:60,start:4" --out shot.png
swift run -c release nesrun navigate zelda.nes --load-state ow.state --to 37
swift run -c release nesrun audio zelda.nes --seconds 12 --out title.wav
swift run -c release nesrun analyze zelda.nes
```

For the iOS app, copy your ROM to `Apps/ZeldaiOS/zelda.nes` and build
`Apps/ZeldaiOS.xcodeproj`. See [docs/ios-app.md](docs/ios-app.md).

## Target cartridge

The retail Zelda cartridge (SNROM board):

| Field | Value |
|---|---|
| PRG-ROM | 128 KB (8 × 16 KB) |
| CHR | 8 KB CHR-**RAM** |
| Mapper | 1 (MMC1) |
| Battery | Yes — 8 KB WRAM at `$6000` |

## ROMs

No ROM is included or committed; `.nes` files and `.state` snapshots are
gitignored. Supply your own dump of a cartridge you own. Each `GameDefinition`
pins an expected SHA-256, so a different dump fails loudly rather than
producing subtle nonsense.

## Approach

The emulator is not the destination — it is the scaffolding. Decompilation
proceeds incrementally, and the emulator serves as both the **oracle** (native
routines are differentially tested against the interpreted 6502, including the
*ordered* side effects) and the **discovery mechanism** (static analysis is
confident about only 1.7% of this ROM; execution traces resolve the indirect
dispatchers it cannot follow). The game stays playable at every step.

See [docs/](docs/) — start with
[architecture.md](docs/architecture.md) and
[decompilation.md](docs/decompilation.md).
