# loz

## Overview

An NES emulator written from scratch in Swift, being incrementally decompiled
into a native Swift port of *The Legend of Zelda* for iPhone, Apple TV, and
macOS. Not for the App Store. One SwiftPM package plus thin Xcode app shells in
`Apps/`. **One app = one game**: no ROM picker, no library UI; each title is a
small game library plus an app target carrying its own game data.

That data is *not* in the repository. `embeddedROM` defaults to nil and the
generated `Sources/ZeldaGame/ZeldaROMData.swift` that fills it in is gitignored,
so a clean checkout builds and falls back to a `.nes` on disk (`docs/rom-free.md`).

The emulator is scaffolding for the decompilation: it is both the **oracle**
(native routines are differentially tested against the interpreted 6502,
including ordered side effects) and the **discovery mechanism** (execution
traces resolve the indirect dispatchers static analysis cannot follow). The game
must stay playable at every step.

## Tech Stack

- Swift 6 (`swift-tools-version: 6.0`), SwiftPM; platforms: macOS 14, iOS 17, tvOS 17.
- No third-party package dependencies; the `nesrun` CLI is hand-rolled on purpose.
- SwiftUI (`NESPlayer` shell), AVAudioEngine (audio), GameController framework.
- Tests use swift-testing (`@Test`, `#expect`), not XCTest — 261 tests in 28 suites.
- swiftformat (`.swiftformat`) for lint. CI (`.github/workflows/ci.yml`) runs three
  jobs on a self-hosted macOS ARM64 runner: build+test+release+CLI smoke, lint,
  and an iOS simulator build.

## Key Concepts & Terminology

- **6502 / PPU / APU / MMC1**: CPU, picture processor, audio processor, and the
  mapper on Zelda's SNROM board — 128 KB PRG in 16 KB banks, 8 KB CHR-**RAM**,
  battery-backed WRAM at `$6000`.
- **Decompilation loop**: pick one 6502 routine → rewrite in Swift → verify
  differentially against the interpreter (`RoutineVerifier`) → register in
  `RoutineTable` keyed by `(bank, address)` with a declared cycle cost (the PPU
  is clocked from CPU cycles, so native code must still "take" cycles).
- **`GameDefinition`**: what an app needs to present exactly one game; pins an
  expected ROM SHA-256 so a wrong dump fails loudly.
- **Snapshots** (`.state`): full machine snapshots that skip the ~520-frame boot
  when driving the game headlessly.
- **Route scripts** (`docs/scripts/*.txt`): committed input sequences that
  regenerate known game states, since the snapshots themselves cannot be
  committed. Each names the RAM address proving it worked; see
  `docs/scripts/README.md` for the chain and how to replay it.

## Environment & Dependencies

- macOS with a Swift 6 toolchain; Xcode for the `Apps/` projects.
- `swiftformat` (brew) for the lint gate.
- `zelda.nes` (your own dump of a cartridge you own; **never committed** —
  `*.nes` is gitignored) beside the package: needed by `zeldamac`/`nesrun` and
  by the routine-equivalence tests. `swift build`/`swift test` do **not** need
  it — tests synthesise iNES images in memory and ROM-dependent tests skip
  cleanly when it is absent.
- The tvOS app builds and runs on the Apple TV simulator. It needs the tvOS
  **platform component** installed; without it only an attempted build is
  diagnostic, since `xcodebuild -showsdks` lists tvOS either way.

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

`nesrun` subcommands — inspection: `info hash analyze disasm`; running: `run
play probe navigate clearroom tiles`; verification: `ramdiff oam mapcheck audio
paltrace`; codegen: `embed`. Run `nesrun` with no arguments for the full flag
list (deliberately exhaustive — a command missing there is a command nobody
finds); input-script syntax (`wait:60,start:4,up+a:12`) and worked examples are
in `docs/agent-harness.md`.

Two harness habits worth having before you start guessing:

- **Use `probe`, not a shell loop.** Deriving a route by invoking `play` once
  per guess is dominated by process start and ROM load, and costs a round trip
  per answer. `probe --load-state S --inputs "right:{0..24/4},up:200" --goal
  00EB=63` restores the same snapshot for every candidate in one process and
  prints one table. Seconds instead of minutes.
- **Use `ramdiff --control`, not a bare before/after.** The raw diff is hundreds
  of bytes of noise; a control run of similar length in which the event did
  *not* happen subtracts everything that moves on its own. Its limit: state that
  changes every frame moves in the control too (enemy tables), so for those
  search for structure instead.

## Project Layout

```
Sources/
  NESCore/     the emulator: CPU6502, PPU, APU, Mapper protocol + MMC1, Cartridge,
               SaveState, RoutineTable, shared opcode table. Ships in every app.
  NESAnalysis/ disassembler, execution tracing, RoutineVerifier — dev only, never shipped
  NESPlayer/   reusable SwiftUI shell: screen, touch/keyboard/controller, saves
  ZeldaGame/   Zelda metadata, symbol map, decompiled routines, expected ROM hash
  nesrun/      CLI harness for the decompilation workflow
  zeldamac/    macOS app, runs straight from SwiftPM — the fast dev loop
Apps/          ZeldaiOS / ZeldatvOS Xcode projects — thin shells, scheme "Zelda".
               PadTest is a standalone GCVirtualController probe, not a game target.
Tests/         NESCoreTests, NESAnalysisTests, NESPlayerTests, ZeldaGameTests
docs/          architecture, decompilation, agent-harness, testing, adding-a-game,
               rom-format, rom-free, emulator-{cpu,ppu,apu,mappers},
               {ios,macos}-app, distribution, gotchas; README.md is the index,
               scripts/ holds the route chain, and issues/ is the roadmap —
               the tracker lives in the repository, not on a server
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
- Symbol-map entries in `Zelda.swift` carry the experiment that found them, not
  just the address — the comment is what makes the next one reproducible.

## Making Changes

* Make minimal, focused changes; avoid broad refactors unless requested.
* Preserve existing architecture and patterns.
* Don't introduce new dependencies without justification.
* Update tests when behavior changes; update docs when user-visible
  behavior, configuration, or workflows change.

- `docs/` is extensive and precise. Keep it in sync — test counts, suite tables,
  command output, the `nesrun` usage text — when you change what it describes.
- A decompiled routine is not done when it compiles. It is done when it passes
  differential verification (`ZeldaGameTests` / `RoutineVerifier`, including
  ordered register writes) and is registered in the `RoutineTable` with a
  bank-scoped key and an honest cycle count.
- **Verify UI changes in both orientations, with a screenshot.** The on-screen
  controls once shipped off-screen in portrait because the layout tests passed
  and only landscape was reviewed by eye. `ControlLayoutTests` covers both now,
  but a passing suite is not a substitute for looking at the thing.
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
  CHR-RAM; regenerate them from `docs/scripts/` instead of committing them. The
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
- Never let a self-hosted CI job run for a pull request from a fork. Every job
  in `ci.yml` is guarded on the PR's head repository, because the runner is a
  Mac on a desk rather than a disposable VM, and the ROM-staging step puts a
  cartridge dump in the workspace. Removing that guard turns a fork PR into
  arbitrary code execution with a copyrighted file next to it.
- Never remove the `unsafeFlags` on `NESCore` in `Package.swift` (`-Ounchecked`
  in release, `-O` in **debug** too): at `-Onone` the interpreter runs ~15 fps
  and looks broken; optimised it holds 60. Note the two are not equivalent
  either — `-Ounchecked` drops bounds and overflow checks, which an interpreter
  pays on every memory access, and it is worth **3.5x** (measured: 163 vs 565
  fps of headroom). A debug build is playable on a phone and not on an Apple TV.
  See `docs/gotchas.md`.
- Never let a hand-written source file reference `ZeldaROMData`. It is generated
  and gitignored, so a direct reference makes a clean checkout fail to compile —
  which broke CI exactly once. The generator (`Sources/nesrun/EmbedROM.swift`)
  emits the `embeddedROM` conformance *into* its own output, so the file's
  absence simply leaves the protocol default of nil.

### Use Extra Caution

- `Sources/NESCore/Opcodes.swift` — one shifted row in the grid silently
  corrupts interpreter and disassembler alike; that is what the alignment-
  preserving format rules protect.
- `Sources/NESAnalysis/RoutineVerifier.swift` — two preconditions separate a real
  comparison from nonsense, both commented at the code. `forceBank` must run: a
  restored snapshot has whatever bank was live when it was captured, not the
  routine's, so without it the verifier executes unrelated bytes at the right
  address. And the run loop steps `nes.cpu.step()`, not `nes.step()` — clocking
  the PPU lets an NMI fire mid-routine and run the whole frame handler, which
  once produced 13,792 writes against an expected 3. Absurd write counts or
  `completed: false` mean these before they mean a bad routine.
- `Sources/ZeldaGame/ZeldaROMData.swift` — generated by `nesrun embed`; do not
  edit by hand. It is gitignored and excluded from swiftformat for that reason.
- `Apps/*.xcodeproj` — the iOS target uses a file-system synchronized group, so
  files added under `Apps/ZeldaiOS/` need no project edit; the ROM is staged
  into the app by CI only if the runner has a local copy.

## Troubleshooting

- **Debug build runs at ~15 fps / "emulator looks broken"**: the `NESCore`
  optimisation flags in `Package.swift` were dropped — restore them.
- **`ZeldaROMData.swift` missing on a clean checkout**: expected and harmless.
  Regenerate with `swift run nesrun embed zelda.nes` for the ROM-free app build.
- **Routine-equivalence tests skip**: they need `zelda.nes` beside the package;
  everything else runs without it.
- **swiftformat lint fails right after a tool upgrade**: likely new rules, not a
  code regression — CI prints the swiftformat version for exactly this reason.
- **A route sweep returns the identical end position for every candidate**: the
  input is doing nothing — Link is boxed in. Move on the other axis first.
  `docs/scripts/README.md` lists the rest of these.

## Agent Notes

This file is symlinked to CLAUDE.md and GEMINI.md; keep all instructions
tool-neutral.
