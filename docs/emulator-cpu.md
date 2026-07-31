# CPU — Ricoh 2A03

A 6502 with decimal mode disabled. `Sources/NESCore/CPU6502.swift`.

This core is not just "the thing that runs the game" — it is the reference
implementation that every decompiled Swift routine gets differentially tested
against. It therefore optimises for exact register and flag semantics over raw
speed. At ~1% of one core, speed was never the constraint.

## Execution model

`step()` executes one instruction and returns the cycles it consumed:

1. Service a stall (OAM DMA), if any
2. Service a pending NMI, or an unmasked IRQ
3. Fetch the opcode, look it up in `Opcodes.table`
4. Resolve the operand address for the addressing mode
5. Add a cycle if indexing crossed a page and this opcode pays that penalty
6. Execute, adding any branch penalty

Interrupts are checked *between* instructions, which is correct for everything
short of cycle-exact interrupt hijacking. No commercial NES game depends on
that.

## Flags

Bit layout, and the two that cause the most emulator bugs:

| Bit | Flag | Notes |
|---|---|---|
| 0 | Carry | Also "no borrow" for SBC and compares |
| 1 | Zero | |
| 2 | Interrupt disable | Masks IRQ, never NMI |
| 3 | Decimal | Settable, but **ignored by arithmetic** on the 2A03 |
| 4 | Break | Not a real register bit — only exists in pushed copies |
| 5 | Unused | Always set in pushed copies |
| 6 | Overflow | Signed overflow |
| 7 | Negative | |

### Overflow

Set only when two like-signed operands produce a differently-signed result:

```swift
setFlag(Flag.overflow, ((a ^ result) & (value ^ result) & 0x80) != 0)
```

All four sign combinations are covered in `CPUArithmeticTests`.

### The B flag

There is no B bit in the physical status register. It only appears in the byte
pushed to the stack, and its value says *why* the push happened:

| Source | B in pushed byte |
|---|---|
| `PHP`, `BRK` | 1 |
| IRQ, NMI | 0 |

`PLP` and `RTI` therefore mask it off and force bit 5 set. Getting this wrong
produces bugs that only surface inside interrupt handlers.

### Decimal mode

The 2A03 has BCD circuitry disabled. `SED` sets the flag and `CLD` clears it,
but `ADC`/`SBC` always operate in binary. Implementing BCD here would be a
*bug*, not extra accuracy.

## Addressing modes

The wrapping rules are where correctness quietly dies. All are tested in
`CPUAddressingTests`.

| Mode | Rule that bites |
|---|---|
| Zero page,X / ,Y | Wraps **within page zero**: `$FF + 2 = $01`, not `$0101` |
| `(zp,X)` | Both pointer bytes wrap in page zero |
| `(zp),Y` | Pointer bytes wrap; the final add can cross a page (+1 cycle) |
| Absolute,X / ,Y | +1 cycle on page cross — for reads only |
| Relative | Signed offset, resolved against the *next* instruction |

Stores never take the page-cross penalty because it is already baked into their
base cycle count. `STA $12F0,X` costs 5 whether it crosses or not.

### The `JMP (indirect)` bug

Reproduced deliberately:

```swift
// JMP ($30FF) reads the low byte from $30FF and the high byte from
// $3000 — wrapping within the page rather than advancing to $3100.
let hiAddr = (addr & 0xFF00) | UInt16((addr &+ 1) & 0x00FF)
```

Real hardware does this. Games occasionally depend on it, and a "fixed" version
would break them.

## Subroutines

`JSR` pushes the address of its own **last byte**, not the next instruction —
so `RTS` pulls and adds one. This matters for the decompiler: a return address
on the stack is `target - 1`.

`push16` writes the high byte first, so a frame reads back from SP as:

```
[SP+1] status   (interrupts and BRK only)
[SP+2] PC low
[SP+3] PC high
```

The test fixture exposes `pushedPC`, `pushedStatus`, and `pushedReturnAddress`
rather than raw offsets, precisely because getting this order wrong is easy and
silent.

## Undocumented opcodes

All 256 entries are populated. The stable illegals (`LAX`, `SAX`, `DCP`, `ISC`,
`SLO`, `RLA`, `SRE`, `RRA`, `ANC`, `ALR`, `ARR`, `AXS`) are implemented properly;
the unstable stores (`AHX`, `SHX`, `SHY`, `TAS`) use the common
"high byte + 1" formulation.

Zelda does not need these, but the **disassembler** does: without them, a byte
of data misread as code would desynchronise the instruction stream rather than
decoding as a recognisable junk instruction.

## Decompilation hooks

Two methods exist solely to support native routines:

```swift
cpu.returnFromSubroutine()   // rejoin the interpreted caller as if RTS ran
cpu.advanceCycles(n)         // charge cycles so the PPU stays in step
```

Plus `NES.onInstruction`, an optional `(bank, PC)` observer used for trace-guided
code discovery. Nil by default, costing one branch.
