# loz

## Overview

An NES emulator written from scratch in Swift, being incrementally decompiled
into a native Swift port of *The Legend of Zelda* for iPhone, Apple TV, and
macOS. Not for the App Store. One SwiftPM package plus thin iOS/tvOS Xcode
shells. **One app = one game**: no ROM picker, no library UI; each title is a
small game library plus a thin app target carrying its own game data.

That data is *not* in the repository. `embeddedROM` defaults to nil, and the
generated `ZeldaROMData.swift` that fills it in is gitignored — so a clean
checkout builds and runs, and falls back to loading a `.nes` from disk. See
`docs/rom-free.md`.

The emulator is scaffolding for the decompilation. It is the **oracle** (native
routines are differentially tested against the interpreted 6502, including
ordered side effects) and the **discovery mechanism** (execution traces resolve
the indirect dispatchers static analysis cannot follow). The game must stay
playable at every step.

## Tech Stack

- Swift 6 (`swift-tools-version: 6.0`), SwiftPM; platforms: macOS 14, iOS 17, tvOS 17.
- No third-party package dependencies; the `nesrun` CLI is hand-rolled on purpose.
- SwiftUI (`NESPlayer` shell), AVAudioEngine (audio), GameController framework.
- Tests use swift-testing (`@Test`, `#expect`), not XCTest.
- swiftformat (`.swiftformat`) for lint; CI on a self-hosted macOS ARM64 runner
  (`.github/workflows/ci.yml`).

## Key Concepts & Terminology

- **6502 / PPU / APU / MMC1**: CPU, picture processor, audio processor, and the
  mapper on Zelda's SNROM cartridge — mapper 1, 128 KB PRG in 16 KB banks,
  8 KB CHR-**RAM**, battery-backed WRAM at `$6000`.
- **Decompilation loop**: pick one 6502 routine → rewrite in Swift → verify
  differentially against the interpreter (`RoutineVerifier`) → register in
  `RoutineTable` keyed by `(bank, address)` with a declared cycle cost (the PPU
  is clocked from CPU cycles, so native code must still "take" cycles).
- **`GameDefinition`**: what an app needs to present exactly one game; pins an
  expected ROM SHA-256 so a wrong dump fails loudly.
- **`nesrun` snapshots** (`.state`): full machine snapshots used to skip the
  ~520-frame boot when driving the game headlessly.

## Environment & Dependencies

- macOS with a Swift 6 toolchain; Xcode for the `Apps/` projects.
- `swiftformat` (brew) for the lint gate.
- `zelda.nes` (your own dump of a cartridge you own; **never committed** —
  `*.nes` is gitignored) beside the package: needed by `zeldamac`/`nesrun` and
  by the routine-equivalence tests. `swift build`/`swift test` do **not** need
  it — tests synthesise iNES images in memory and ROM-dependent tests skip
  cleanly when it is absent.
- The tvOS app is written but has never been compiled: the tvOS **platform
  component** is not installed. Do not check this with `xcodebuild -showsdks` —
  it lists tvOS anyway. The real answer comes from attempting a build, which
  fails with "tvOS N is not installed. Please download and install the platform
  from Xcode > Settings > Components."

## Commands

```sh
swift build && swift test        # build + full suite (fast; no ROM needed)
swift test --filter PPUTests     # one suite (regex over target/test names)
swift build -c release           # release build (also a CI step)
swiftformat Sources Tests --lint --cache ignore   # CI lint gate; drop --lint to apply

swift run -c release zeldamac zelda.nes           # play on macOS
swift run -c release nesrun <cmd> zelda.nes ...   # CLI harness (see below)
swift run nesrun embed zelda.nes   # generate Sources/ZeldaGame/ZeldaROMData.swift (gitignored)

# iOS app (CI gate):
xcodebuild -project Apps/ZeldaiOS.xcodeproj -scheme Zelda \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

`nesrun` subcommands: `info hash analyze disasm run play embed probe mapcheck
navigate audio paltrace`. Run `nesrun` with no arguments for the full flag
list; input-script syntax (`wait:60,start:4,up+a:12`) and worked examples are
in `docs/agent-harness.md`.

**Use `probe`, not a shell loop.** Working out an unknown route by invoking
`play` once per guess is dominated by process start and ROM load, and costs a
round trip per answer. `probe --load-state S --inputs "right:{0..24/4},up:200"
--goal 00EB=63` restores the same snapshot for every candidate in one process
and prints one table. Seconds instead of minutes.

## Project Layout

```
Sources/
  NESCore/     the emulator: CPU6502, PPU, APU, Mapper protocol + MMC1, Cartridge,
               SaveState, RoutineTable, shared opcode table. Ships in every app.
  NESAnalysis/ disassembler, execution tracing, RoutineVerifier — dev only, never shipped
  NESPlayer/   reusable SwiftUI shell: screen, touch/keyboard/controller, saves
  ZeldaGame/   Zelda metadata, symbol map, decompiled routines, expected ROM hash
  nesrun/      CLI harness for the decompilation workflow
  zeldamac/    macOS app, runs straight from SwiftPM
Apps/          ZeldaiOS / ZeldatvOS Xcode projects — thin shells, scheme "Zelda"
Tests/         NESCoreTests, NESPlayerTests, ZeldaGameTests
docs/          architecture, decompilation, agent-harness, testing, adding-a-game,
               rom-format, rom-free, emulator-{cpu,ppu,apu,mappers},
               {ios,macos}-app, distribution; README.md is the index
Reference/     first-quest overworld map PNG for `nesrun mapcheck` — gitignored
               and supplied locally; it is built from ripped game graphics
```

## Code Style & Patterns

- Follow `.swiftformat`: 4-space indent, 96-column soft limit, no `self.` unless
  required, `0..<n` ranges. Several wrap/spacing rules are **deliberately
  disabled** so the opcode table, NES palette, and APU period tables stay in
  aligned grids that are checkable by eye — do not "fix" their alignment.
- `Opcodes.table` is a single 256-entry table consumed by both the interpreter
  and the disassembler; the two can never disagree about what a byte means.
- Layering: `NESCore` has no UI and no game-specific knowledge; `NESPlayer` is
  game-agnostic (parameterised by `GameDefinition`); everything cartridge-
  specific goes in `ZeldaGame`; a second game is a new `*Game` target plus a
  mapper, not a fork.
- Tests build synthetic in-memory iNES cartridges — never require a real ROM.
  `CPUFixture` loads bytes into a flat bus; assert flags through datasheet-named
  accessors (`carry`, `overflow`, …) and timing through `step()`'s cycle return.
- Decompiled routines use `CPU6502`'s flag-exact helpers (`addWithCarry`,
  `subtractWithCarry`, `compareValues`, `shiftLeft`, …) rather than re-deriving
  flag semantics by hand.

## Making Changes

* Make minimal, focused changes; avoid broad refactors unless requested.
* Preserve existing architecture and patterns.
* Don't introduce new dependencies without justification.
* Update tests when behavior changes; update docs when user-visible
  behavior, configuration, or workflows change.

- `docs/` is extensive and precise (architecture, decompilation, harness,
  testing, iOS). Keep it in sync — test counts, suite tables, command output —
  when you change what it describes.
- A decompiled routine is not done when it compiles. It is done when it passes
  differential verification (`ZeldaGameTests` / `RoutineVerifier`, including
  ordered register writes) and is registered in the `RoutineTable` with a
  bank-scoped key and an honest cycle count.
- **Verify UI changes in both orientations, with a screenshot.** The on-screen
  controls once shipped off-screen in portrait: the layout tests passed and
  landscape was reviewed by eye, so nothing caught it until a portrait
  screenshot did. `ControlLayoutTests` now covers both, but a passing suite is
  not a substitute for looking at the thing.
- **A verified routine is a claim about the emulator too.** If the interpreter
  is wrong, differential testing bakes the bug into "verified" native code and
  makes it far harder to find. Prefer fixing the oracle over matching it.

## Guardrails

### Always

- Run `swift build && swift test` and `swiftformat Sources Tests --lint
  --cache ignore` before considering work done — both are CI gates, and the
  suite needs no ROM.
- Keep all cartridge data out of git: `.nes`, `.sav`, `.srm`, `.state`,
  `Reference/*.png`, and `Sources/*/ROMData.swift` + `Sources/*/ZeldaROMData.swift`
  are gitignored because they *are* the copyrighted game. Snapshots embed
  CHR-RAM; regenerate them with the committed script
  `docs/scripts/boot-to-overworld.txt` instead of committing them. The
  overworld map is ripped graphics with Nintendo's copyright notice rendered
  into the image — it was committed once and had to be purged from history.

### Never

- Never commit a ROM, a snapshot, the generated `ZeldaROMData.swift`, or a
  reference map — that puts back exactly what was deliberately kept out of the
  repository.
- Never add game artwork, sprites, tiles, or maps. `LICENSE` states what this
  repository does and does not cover; anything Nintendo-derived that lands here
  makes that statement false. The two exceptions are named explicitly in
  `LICENSE` and are not a precedent for more.
- Never make a shipping target (`NESCore`, `NESPlayer`, `ZeldaGame`, the apps)
  depend on `NESAnalysis` — the shipping binary must not contain a disassembler.
- Never add an external dependency for `nesrun`'s CLI parsing — "no external
  dependencies while the core is in flux" (comment in `main.swift`).
- Never remove the `-O`/`unsafeFlags` on `NESCore` in `Package.swift`: at
  `-Onone` the interpreter runs ~15 fps and looks broken; at `-O` it holds 60.
- Never let a hand-written source file reference `ZeldaROMData`. That file is
  generated and gitignored, so a direct reference makes a clean checkout fail
  to compile — which broke CI exactly once. `nesrun embed` generates the
  `embeddedROM` conformance *inside* the generated file (`EmbedROM.swift`) so
  its absence simply leaves the protocol default of nil.

### Use Extra Caution

- `Sources/NESCore/Opcodes.swift` — one shifted row in the grid silently
  corrupts interpreter and disassembler alike; that is what the alignment-
  preserving format rules protect.
- `Sources/NESAnalysis/RoutineVerifier.swift` — two preconditions make the
  difference between a real comparison and nonsense, both commented at the
  code. `forceBank` must run because a restored snapshot has whatever bank was
  live when it was captured, not the routine's; without it the verifier
  executes unrelated bytes at the right address. And the run loop steps
  `nes.cpu.step()`, not `nes.step()` — clocking the PPU lets an NMI fire
  mid-routine and run the game's whole frame handler, which once produced
  13,792 writes against an expected 3. If verification reports absurd write
  counts or `completed: false`, suspect these before suspecting the routine.
- `Sources/ZeldaGame/ZeldaROMData.swift` — generated by `nesrun embed`; do not
  edit by hand (and it is gitignored anyway).
- `Apps/*.xcodeproj` — the iOS target uses a file-system synchronized group, so
  files added under `Apps/ZeldaiOS/` need no project edit; the ROM is staged
  into the app by CI only if the runner has a local copy.

## Troubleshooting

- **Debug build runs at ~15 fps / "emulator looks broken"**: the `NESCore`
  optimisation flags in `Package.swift` were dropped — restore them.
- **`ZeldaROMData.swift` missing on a clean checkout**: expected. It is
  generated and gitignored, and the package builds without it (`embeddedROM`
  stays nil). Regenerate with `swift run nesrun embed zelda.nes` when you want
  the ROM-free app build.
- **Routine-equivalence tests skip**: they need `zelda.nes` beside the package;
  everything else runs without it.
- **swiftformat lint fails right after a tool upgrade**: likely new rules, not a
  code regression — CI prints the swiftformat version for exactly this reason.

## Agent Notes

This file is symlinked to CLAUDE.md and GEMINI.md; keep all instructions
tool-neutral.
