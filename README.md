# loz

An NES emulator written from scratch in Swift, built to play a personally-owned
copy of *The Legend of Zelda* on iPhone, Apple TV, and macOS. Not for the App Store.

## Status

Early scaffolding. See `Sources/NESCore/`.

## Target cartridge

The retail Zelda cartridge (SNROM board) reports:

| Field | Value |
|---|---|
| PRG-ROM | 128 KB (8 × 16 KB) |
| CHR | 8 KB CHR-**RAM** (no CHR-ROM banks) |
| Mapper | 1 (MMC1) |
| Mirroring | Horizontal (mapper-controlled) |
| Battery | Yes — 8 KB WRAM at `$6000`, persisted as a `.sav` |

The core is not Zelda-specific, but MMC1 is the only mapper needed to run it.

## Layout

```
Sources/
  NESCore/     Platform-agnostic emulator (CPU, PPU, APU, mappers)
  nesrun/      macOS CLI harness — boots a ROM, dumps frames for verification
```

## ROMs

No ROM is included or committed; `.nes` files are gitignored. Supply your own
dump of a cartridge you own.

## Building

```sh
swift build
swift run nesrun path/to/zelda.nes --frames 120 --out frame.ppm
```
