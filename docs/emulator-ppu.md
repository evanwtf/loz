# PPU — Ricoh 2C02

`Sources/NESCore/PPU.swift`. Dot-based: `step()` advances one PPU cycle, and
the CPU runs one cycle per three dots.

## Frame geometry

341 dots × 262 scanlines:

| Scanlines | Role |
|---|---|
| 0–239 | Visible |
| 240 | Post-render (idle) |
| 241–260 | Vblank — flag set and NMI fired at scanline 241, dot 1 |
| 261 | Pre-render — flags cleared, vertical scroll restored |

On odd frames with rendering enabled, the pre-render line is one dot short. This
is implemented; it produces the half-pixel jitter real hardware has.

## The loopy scroll model

The single most important design decision in the PPU. Scroll state lives in four
registers:

| Register | Meaning |
|---|---|
| `v` | Current VRAM address, 15 bits |
| `t` | Temporary address / topmost scroll latch |
| `fineX` | Fine X scroll, 3 bits |
| `writeToggle` | First/second write flag, **shared by `$2005` and `$2006`** |

`v` and `t` are not just addresses — they pack the scroll position:

```
yyy NN YYYYY XXXXX
||| || ||||| +++++-- coarse X   (which tile column)
||| || +++++-------- coarse Y   (which tile row)
||| ++-------------- nametable select
+++----------------- fine Y     (which pixel row within the tile)
```

This formulation is the only one that gets mid-frame scroll splits right, and
Zelda's status bar is exactly such a split. A naive "scrollX/scrollY variable"
PPU renders Zelda's HUD wrong.

Register writes decompose as:

| Write | Effect |
|---|---|
| `$2000` | `t` bits 10–11 ← nametable select |
| `$2005` first | `t` coarse X ← `d >> 3`; `fineX` ← `d & 7` |
| `$2005` second | `t` fine Y and coarse Y ← `d` |
| `$2006` first | `t` high byte ← `d & 0x3F`; bit 14 cleared |
| `$2006` second | `t` low byte ← `d`, then **`v = t`** |

During rendering, `v` is updated by hardware: coarse X increments every 8 dots,
Y increments at dot 256, horizontal bits are restored from `t` at dot 257, and
vertical bits are restored repeatedly across dots 280–304 of the pre-render line.

Note the coarse-Y wrap: row 29 wraps to 0 *and flips the vertical nametable*,
but rows 30–31 (the attribute-table region, addressable but not a real row) wrap
without flipping.

## Background pipeline

Every 8 dots the PPU fetches one tile's worth of data, staged through latches
into 16-bit shift registers so the *next* tile is queued while the current one
is being displayed:

| `dot % 8` | Fetch |
|---|---|
| 1 | Nametable byte — `$2000 \| (v & 0x0FFF)` |
| 3 | Attribute byte — `$23C0 \| (v & 0x0C00) \| ((v >> 4) & 0x38) \| ((v >> 2) & 0x07)` |
| 5 | Pattern low plane |
| 7 | Pattern high plane |
| 0 | Increment coarse X, load shift registers |

One attribute byte covers a 4×4 tile area, so after fetching it the correct
2-bit quadrant is selected with `shift = ((v >> 4) & 4) | (v & 2)`.

`fineX` selects which bit of the shift registers becomes the current pixel,
which is what makes sub-tile horizontal scrolling work.

## Sprites

Up to 8 per scanline, evaluated at dot 257 for the *next* line. Real hardware
spreads evaluation across dots 65–256; doing it in one go is indistinguishable
unless a game rewrites OAM mid-scanline.

### The off-by-one that mattered

OAM byte 0 stores **Y minus one**. A sprite at `Y` occupies scanlines
`Y+1 … Y+height`, so the pattern row is:

```swift
let row = targetScanline - spriteY - 1
```

The original implementation omitted the `- 1`, drawing every sprite one pixel
too high and firing sprite-0 hit one scanline early. It was caught by
`sprite0StartsOneScanlineBelowOAMY`, not by looking at screenshots — a one-pixel
sprite offset is invisible by eye but corrupts split timing.

### 8×16 sprites

Bit 0 of the tile index selects the pattern table (not `PPUCTRL`), and the tile
index is masked to even. Row ≥ 8 uses the following tile.

## Sprite 0 hit

The flag Zelda uses to split its status bar. Set when an opaque sprite-0 pixel
overlaps an opaque background pixel, subject to every one of these:

- Both background and sprite rendering enabled
- Pixel is not at x = 255
- If x < 8, both left-column mask bits must be set
- Both pixels non-transparent (colour index ≠ 0)

Cleared on the pre-render line. All boundary conditions are covered in
`PPUTests`.

## Palette memory

32 bytes at `$3F00-$3F1F`, mirrored every 32 bytes through `$3FFF`. The sprite
backdrop entries alias the background ones:

```swift
var index = address & 0x1F
if index & 0x13 == 0x10 { index &= ~0x10 }   // $3F10/$14/$18/$1C -> $3F00/$04/$08/$0C
```

A consequence worth knowing when debugging: raw `paletteRAM[16]` is never
written, because writes to `$3F10` are redirected. Dumping the array directly is
misleading — read through `ppuRead`.

## `$2007` read buffering

Reads below `$3F00` return the **previous** buffered byte; the fetched byte
replaces the buffer. Palette reads are immediate but still refill the buffer
from the nametable mirrored underneath. Games do a dummy read after setting an
address, and code that skips it reads garbage.

## Output format

`framebuffer` is `[UInt32]`, 256×240, packed `0xAABBGGRR` — which on a
little-endian machine is byte order R,G,B,A. That uploads directly to a
`.rgba8Unorm` Metal texture or a `CGImage` with `noneSkipLast`, with no
per-pixel conversion.
