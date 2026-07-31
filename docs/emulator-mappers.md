# Mappers

A mapper is the logic on the cartridge that decodes addresses and switches
banks. `Sources/NESCore/Mapper.swift`.

## The protocol

```swift
public protocol Mapper: AnyObject {
    func cpuRead(_ address: UInt16) -> UInt8?     // nil = no response (open bus)
    func cpuWrite(_ address: UInt16, _ value: UInt8)
    func ppuRead(_ address: UInt16) -> UInt8
    func ppuWrite(_ address: UInt16, _ value: UInt8)
    var mirroring: Mirroring { get }

    var currentPRGBank: Int { get }                // for routine keys
    func ppuAddressChanged(_ address: UInt16)      // for scanline IRQs
    var irqAsserted: Bool { get }
    var persistentState: [UInt8] { get set }       // for save states
}
```

The last four have default implementations, so a mapper with no banking and no
IRQ (NROM) implements only the first five members.

### Why `currentPRGBank` exists

Decompiled routines are keyed by `(bank, address)`, because under banking a bare
address is ambiguous — `$8000` means eight different things in Zelda. The
dispatcher asks the mapper what is currently mapped before looking up a routine.

### Why `ppuAddressChanged` exists

MMC3 counts scanlines by watching PPU address line A12 rise, which is how Super
Mario Bros. 3 splits its status bar. `PPU.ppuRead` notifies the mapper on every
pattern-table fetch. Mappers without an IRQ ignore it.

## Mirroring

Two physical 1 KB nametables are mapped across four logical slots:

| Mode | Layout |
|---|---|
| Horizontal | Tables 0,1 → bank 0; tables 2,3 → bank 1 |
| Vertical | Tables 0,2 → bank 0; tables 1,3 → bank 1 |
| Single-screen low/high | All four → one bank |
| Four-screen | Requires cartridge VRAM; unsupported |

`Mirroring.vramIndex(for:)` does the mapping. Note MMC1 changes mirroring at
runtime, so this is read from the mapper on every access rather than cached.

## NROM (mapper 0)

No banking. A 16 KB cartridge mirrors its single bank across both slots. Used by
the synthetic cartridges in the test suite.

## MMC1 (mapper 1) — Zelda's board

Registers are written **one bit at a time**. Five consecutive writes to
`$8000-$FFFF` shift bits into an internal register; the fifth commits it to
whichever of four registers the *final* address selects:

| Address range | Register |
|---|---|
| `$8000-$9FFF` | Control (mirroring, PRG mode, CHR mode) |
| `$A000-$BFFF` | CHR bank 0 |
| `$C000-$DFFF` | CHR bank 1 |
| `$E000-$FFFF` | PRG bank |

Writing a value with **bit 7 set** resets the shift register and forces PRG
mode 3 — this is how games re-synchronise if an interrupt lands mid-sequence.

### PRG modes

| Mode | Layout |
|---|---|
| 0, 1 | Switch 32 KB at `$8000` (low bit of bank number ignored) |
| 2 | Fix bank 0 at `$8000`, switch at `$C000` |
| 3 | Switch at `$8000`, **fix last bank at `$C000`** — Zelda's mode |

Mode 3 is why the interrupt vectors are always reachable: they live at the top
of the last bank, which is permanently mapped.

### SNROM specifics

Zelda's board carries 8 KB of CHR-**RAM** rather than CHR-ROM, so the CHR bank
registers do nothing for graphics — tiles are uploaded through `$2007` at
runtime. Bit 4 of the PRG bank register disables the battery-backed WRAM at
`$6000`.

### Known simplification

Consecutive-cycle writes are not ignored. On real hardware, a read-modify-write
instruction like `INC $8000` performs two writes on adjacent cycles and the
second is discarded. Zelda uses ordinary `STA` sequences and is unaffected. A
game that relies on this would need the CPU to expose write cycle numbers to the
mapper.

## Adding a mapper

1. Implement `Mapper` in `Sources/NESCore/`
2. Add a case to `Cartridge.makeMapper()`
3. Implement `persistentState` so save states survive
4. If it has a scanline IRQ, implement `ppuAddressChanged` and `irqAsserted` —
   `NES.step` already polls the latter every instruction
5. Unit-test the banking arithmetic directly; do not rely on a game booting as
   your only signal

### MMC3 notes (for SMB3)

The A12 filter is the part that goes wrong. A12 must be seen as *low* for a
sustained period before a rise counts, otherwise consecutive pattern fetches
generate spurious edges and the IRQ fires on the wrong scanline — visible as a
tearing or jittering status bar. Track dot-distance since A12 last went low
rather than treating every rise as a clock.

Tracked in [#11](../../../issues/11).
