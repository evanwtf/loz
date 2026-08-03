# Shipping without a ROM

The end state is an app that contains no `.nes` file — the game as native Swift.
This is the logical conclusion of the decompilation track, and it is worth being
precise about what it requires, because "decompile the code" is only a third of
the job.

## Three things live in that ROM

| Component | Size | What it is | Status |
|---|---|---|---|
| **Code** | ~35 KB reached | ~1000+ 6502 routines | 5 converted |
| **Data** | most of 128 KB | Level layouts, room definitions, text, item and enemy tables, music sequences, palettes | not started |
| **Graphics** | uploaded to 8 KB CHR-RAM | Tile patterns for everything on screen | not started |

Only the first is decompilation in the usual sense. The other two are
*extraction*: reading structured data out of the ROM and re-expressing it as
Swift source or bundled resources.

A useful sense of proportion: `nesrun analyze` reaches ~27% of PRG as code even
counting speculation, and only 1.7% confidently. **Most of this cartridge is
data, not instructions.** The decompilation is the hard part; the extraction is
the large part.

## What "no ROM" does and does not change

It removes the `.nes` file. It does not remove Nintendo's content — the level
layouts, tile graphics, and music still exist in the app, expressed as Swift
source and assets instead of a cartridge image. That is a difference in
representation, not in what the app contains.

Worth knowing when deciding how the result gets distributed. It does not change
the engineering.

## The path

1. **Code** — continue the verified conversion loop
   ([decompilation.md](decompilation.md)). Each routine is proven equivalent
   before it is trusted.
2. **Graphics** — extract CHR tile patterns. Zelda uses CHR-**RAM**, so tiles
   are copied out of PRG at runtime rather than being addressable directly;
   finding them means tracing what the loader reads.
3. **Data** — identify each table by watching what decompiled routines index
   into, then emit it as typed Swift rather than raw bytes. This is where the
   port stops being a transliteration and starts being readable: a room becomes
   a `Room` value, not an offset into a blob.
4. **Rendering** — replace PPU emulation with direct drawing from native state
   ([#10](issues/0010-native-renderer-draw-from-game-state-instead-of-emulating-th.md)).
5. **Drop the ROM** — once nothing reads it, remove the resource and the hash
   check with it.

## How you know you are done

The honest test is mechanical, and the harness already supports it: run the
native build and a ROM-backed emulator side by side from the same input script
and compare framebuffers. `mapcheck` and the differential verifier are the same
idea applied to smaller pieces.

Until every routine is converted, the ROM stays — a half-converted build needs
the interpreter for whatever is left, and the interpreter needs the cartridge.
There is no partial credit on removing the file, which is exactly why the
incremental approach keeps the ROM until the very end and stays playable the
whole way.
