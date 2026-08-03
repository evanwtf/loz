# #15 — Harden the static analyzer against decoding data as code

| | |
|---|---|
| **State** | closed |
| **Labels** | bug, tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

`nesrun analyze` currently reports calls to addresses like $0000, $0004, $6D7C, $7013 — the $6xxx/$7xxx range is SRAM, which Zelda does not execute from. These are false positives.

**Cause**: pass 2 re-traces every discovered entry point against all 8 banks, because MMC1 makes a bare address ambiguous. In banks where that address holds data, the tracer decodes data bytes as instructions and invents JSR targets.

**Fixes to consider**
- Weight or gate pass 2 on evidence that the address is actually code in that bank
- Drop traces that reach implausible targets (SRAM, $0000-$1FFF, open bus)
- Prefer dynamic bank attribution from #5 over the all-banks guess
- Report confidence per routine rather than a flat list

Mostly obsoleted by trace-guided discovery (#5), but the static pass should still not emit results it cannot justify.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Fixed by separating confident from speculative findings rather than trying to make pass 2 accurate.

The headline "27% code" was mostly speculation:

| | Bytes | Share |
|---|---|---|
| Confident (vectors, fixed bank) | 2,187 | **1.7%** |
| Speculative (entry retried per bank) | 32,587 | 24.8% |

Speculative paths now abandon as soon as they call somewhere real code never would — RAM, the PPU/APU window, or SRAM at $6000-$7FFF. That removed **54 phantom routines** (170 → 116). The implausible targets are still recorded in `callsOutsideROM` as a diagnostic.

The honest split is the useful output: static analysis confidently knows 1.7% of this ROM, while execution tracing (#5) has already covered 4.7%.
