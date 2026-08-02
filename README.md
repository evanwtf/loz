# loz

An NES emulator written from scratch in Swift, being incrementally decompiled
into a native Swift port of *The Legend of Zelda*, to run on iPhone, Apple TV,
and macOS. Not for the App Store.

Four surfaces: a SwiftPM package of emulator libraries, a `nesrun` CLI for
driving the game headlessly, a macOS app, and iOS/tvOS Xcode targets.
**One app = one game** — no ROM picker, no game library. Each title is a small
game target plus a thin app target that embeds its own ROM.

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

232 tests across 24 suites. CI green on a self-hosted macOS runner.

## You must supply the ROM

**This repository does not include the game, and none is provided.** To run
anything that plays Zelda you need `zelda.nes` — your own dump of a cartridge
you own — placed beside the package. Where you get it is your problem, not this
project's; no ROM, link, or download is offered here, and requests for one will
not be answered.

`.nes` files, `.state` snapshots, and the overworld reference map are all
gitignored, so nothing derived from the cartridge can be committed by accident.
`GameDefinition` pins an expected SHA-256, so a wrong dump fails loudly rather
than producing subtle nonsense.

`swift build` and `swift test` do **not** need it: the tests synthesise iNES
images in memory, and the ROM-dependent tests skip cleanly when it is absent.

## Usage

### Playing

```sh
swift run -c release zeldamac zelda.nes        # macOS window
swift run -c release zeldamac zelda.nes --selftest   # headless health check
```

Keyboard: arrows for the d-pad, `Z`/`X` for B/A, Return/Space for START/SELECT,
`P` pause, `R` reset, `D` diagnostics, `F` fast-forward. MFi, Xbox, and
DualSense controllers connect automatically. `--selftest` runs 300 frames with
no window and exits non-zero if the framebuffer is blank or audio is off-rate —
the way to check the macOS path over SSH or on a display-less runner
([docs/macos-app.md](docs/macos-app.md)).

### `nesrun` — the headless harness

```sh
swift run -c release nesrun <command> zelda.nes [options]
swift run -c release nesrun                    # full flag list
```

| Command | Purpose |
|---|---|
| `info` | Cartridge geometry and interrupt vectors |
| `hash` | SHA-256, for pinning a `GameDefinition` |
| `analyze` | Static code/data analysis, split by confidence |
| `disasm --bank N` | Annotated listing for one 16 KB bank |
| `run --frames N` | Boot headlessly and dump the framebuffer |
| `play` | Scripted input, screenshots, snapshots, tracing |
| `probe --inputs P` | Many candidate scripts in one process |
| `navigate --to XX` | Pathfind to an overworld screen |
| `clearroom` | Fight the current room empty, then collect the drop |
| `tiles` | Read room geometry from the nametable; route across it |
| `ramdiff --control C` | Which RAM addresses an event moved |
| `oam` | Actors on screen — Link, enemies, items — with positions |
| `mapcheck` | Score a rendered screen against the reference map |
| `audio --seconds N` | Render the APU to a WAV with signal statistics |
| `paltrace` | Log every write reaching palette memory |
| `embed` | Emit the ROM as Swift source ([docs/rom-free.md](docs/rom-free.md)) |

Input scripts are `button:frames` segments, comma-separated, combined with `+`:

```sh
swift run -c release nesrun play zelda.nes --input "wait:60,start:4,up+a:12" --out shot.png
swift run -c release nesrun navigate zelda.nes --load-state ow.state --to 37
swift run -c release nesrun audio zelda.nes --seconds 12 --out title.wav
```

Buttons: `up down left right a b start select wait`.

**Use `probe`, not a shell loop.** Running `play` once per guess is dominated by
process start and ROM load. `probe` restores the same snapshot for every
candidate in one process and prints one table:

```sh
swift run -c release nesrun probe zelda.nes --load-state ow.state \
  --inputs "right:{0..24/4},up:200" --goal 00EB=63
```

`mapcheck` exits non-zero when correlation falls below `--threshold`, so it
works as a check in a script. Full syntax and worked examples are in
[docs/agent-harness.md](docs/agent-harness.md).

### Libraries

The package exposes four products, usable from another SwiftPM project:

| Product | Contents |
|---|---|
| `NESCore` | CPU, PPU, APU, mappers, cartridge, save states, native-routine dispatch |
| `NESPlayer` | SwiftUI shell: screen, touch/keyboard/controller input, saves |
| `NESAnalysis` | Disassembler, execution tracing, routine verifier — **dev only** |
| `ZeldaGame` | Zelda metadata, symbol map, decompiled routines |

`NESCore` has no UI and no game-specific knowledge; `NESPlayer` is parameterised
by a `GameDefinition`. A shipping app must never depend on `NESAnalysis` — the
binary should not contain a disassembler.

## Build and run

**Prerequisites.** macOS with a Swift 6 toolchain (`swift-tools-version: 6.0`;
platforms are macOS 14, iOS 17, tvOS 17). Xcode for the `Apps/` projects.
[swiftformat](https://github.com/nicklockwood/SwiftFormat) for the lint gate.
No third-party package dependencies.

```sh
swift build && swift test                          # both CI gates; no ROM needed
swift test --filter PPUTests                       # one suite
swift build -c release
swiftformat Sources Tests --lint --cache ignore    # drop --lint to apply
```

For the iOS app, compile your ROM into the binary once, then build the Xcode
project:

```sh
swift run nesrun embed zelda.nes    # writes Sources/ZeldaGame/ZeldaROMData.swift (gitignored)

xcodebuild -project Apps/ZeldaiOS.xcodeproj -scheme Zelda \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

[docs/ios-app.md](docs/ios-app.md) covers the app itself;
[docs/distribution.md](docs/distribution.md) covers getting it onto a device.

## Project layout

```
Sources/       the four library targets above, plus:
  nesrun/      CLI harness
  zeldamac/    macOS app, runs straight from SwiftPM
Apps/          iOS and tvOS app targets (scheme "Zelda"), plus PadTest
Reference/     Overworld map for `mapcheck` — supplied locally, not committed
docs/          Architecture, internals, harness guide
```

Adding Super Mario Bros. 3 means a new `SMB3Game` target and an MMC3 mapper
([#11](../../issues/11)) — not a fork of any of this.

The target cartridge is retail Zelda on an SNROM board — 128 KB PRG in 16 KB
banks, 8 KB CHR-**RAM**, MMC1, battery-backed WRAM at `$6000`. Details in
[docs/rom-format.md](docs/rom-format.md).

## Troubleshooting

| Symptom | Cause |
|---|---|
| Emulator runs at ~15 fps and looks broken | The `NESCore` optimisation flags in `Package.swift` were dropped. An interpreter is the worst case for `-Onone`. |
| `ZeldaROMData.swift` missing on a clean checkout | Expected — it is generated and gitignored. Run `nesrun embed`. |
| Routine-equivalence tests skip | They need `zelda.nes` beside the package. Everything else runs without it. |

## Approach

The emulator is not the destination — it is the scaffolding. Decompilation
proceeds incrementally, and the emulator serves as both the **oracle** (native
routines are differentially tested against the interpreted 6502, including the
*ordered* side effects) and the **discovery mechanism** (static analysis is
confident about only 1.7% of this ROM; execution traces resolve the indirect
dispatchers it cannot follow). The game stays playable at every step.

See [docs/](docs/README.md) — start with
[architecture.md](docs/architecture.md) and
[decompilation.md](docs/decompilation.md). Working on this repo with a coding
agent? [AGENTS.md](AGENTS.md) has the conventions and guardrails.

## License

[0BSD](LICENSE) — do what you like, attribution not required.

That covers the emulator, the player shell, the analysis tools, and the
harness. It does not cover what is derived from Nintendo's work and is not mine
to license: the app icon, and the converted routines and symbol map in
`Sources/ZeldaGame/`. See [LICENSE](LICENSE) for the exact scope. Not
affiliated with or endorsed by Nintendo.
