# ROM format

## iNES header

16 bytes. `Sources/NESCore/Cartridge.swift`.

| Byte | Meaning |
|---|---|
| 0–3 | Magic `NES\x1A` |
| 4 | PRG-ROM size in 16 KB units |
| 5 | CHR-ROM size in 8 KB units — **0 means the board has CHR-RAM** |
| 6 | Flags: mirroring, battery, trainer, low mapper nibble |
| 7 | Flags: high mapper nibble, NES 2.0 marker |
| 8–15 | Padding in iNES 1.0 |

Flags 6, bit by bit:

| Bit | Meaning |
|---|---|
| 0 | 0 = horizontal mirroring, 1 = vertical |
| 1 | Battery-backed WRAM present at `$6000` |
| 2 | 512-byte trainer follows the header |
| 3 | Four-screen VRAM |
| 4–7 | Low nibble of the mapper number |

### The DiskDude quirk

Some 1990s dumping tools wrote ASCII into bytes 7–15 (famously `DiskDude!`),
which corrupts the high mapper nibble. The parser distrusts byte 7 when bytes
12–15 are non-zero:

```swift
if data[12...15].contains(where: { $0 != 0 }) { flags7 = 0 }
```

## What Zelda reports

```
4E 45 53 1A  08 00 12 00
```

| Field | Value |
|---|---|
| PRG-ROM | 8 × 16 KB = **128 KB** |
| CHR | 0 banks → **8 KB CHR-RAM** |
| Mapper | `(0x12 >> 4) \| (0x00 & 0xF0)` = **1 (MMC1)** |
| Mirroring | Horizontal (but MMC1 overrides it at runtime) |
| Battery | Yes |

File size 131,088 = 16 header + 131,072 PRG, with no CHR data — consistent with
CHR-RAM.

This is the retail SNROM board. Confirmed hash:

```
89232edf4f9b52e3cb872094bc78973de080befca2ddea893b6e936066514d4e
```

## Memory the cartridge provides

| Region | Size | Notes |
|---|---|---|
| PRG-ROM | 128 KB | Banked into `$8000-$FFFF` by MMC1 |
| CHR-RAM | 8 KB | Pattern tables; written through `$2007` |
| PRG-RAM | 8 KB | `$6000-$7FFF`, battery-backed — the three save slots |

The battery RAM is what gets written out as a `.sav`. Because it is plain WRAM,
saving is just persisting `cartridge.prgRAM`.

## ROM validation

Each `GameDefinition` pins an expected SHA-256 and mapper number:

```swift
try Zelda.validate(romData: bytes, cartridge: cartridge)
```

This exists for a specific failure mode. Once routines are decompiled, applying
them to a *different* dump — a European revision, a hacked ROM, a bad dump —
would produce behaviour that is wrong in subtle, extremely hard to diagnose
ways. Failing loudly at load is much cheaper.

Compute a hash with:

```sh
nesrun hash zelda.nes
```

## Licensing note

No ROM is committed. `.nes` files and `.state` snapshots are gitignored — the
latter because they embed CHR-RAM, which is game data. Input scripts that
regenerate a snapshot are committed instead, which keeps the workflow
reproducible without redistributing anything from the cartridge.
