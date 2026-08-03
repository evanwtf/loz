# Documentation

## Start here

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Library split, why it is shaped this way, data flow |
| [decompilation.md](decompilation.md) | The actual goal, and the strategy that makes it tractable |
| [agent-harness.md](agent-harness.md) | Driving the game without a human |

## Emulator internals

| Document | What it covers |
|---|---|
| [emulator-cpu.md](emulator-cpu.md) | 6502 core, addressing, interrupts, the bugs worth reproducing |
| [emulator-ppu.md](emulator-ppu.md) | Loopy scroll model, background pipeline, sprites, sprite-0 hit |
| [emulator-apu.md](emulator-apu.md) | Five channels, the frame counter, non-linear mixing, resampling |
| [emulator-mappers.md](emulator-mappers.md) | MMC1, the `Mapper` protocol, adding MMC3 |
| [rom-format.md](rom-format.md) | iNES parsing and what Zelda's cartridge actually reports |

## Practice

| Document | What it covers |
|---|---|
| [testing.md](testing.md) | Test philosophy, what each suite guards, how to add more |
| [adding-a-game.md](adding-a-game.md) | Shipping a second title without forking anything |
| [rom-free.md](rom-free.md) | Removing the `.nes` dependency; what is left to extract |
| [ios-app.md](ios-app.md) | The iPhone app: layout, controls, audio, saves, diagnostics |
| [macos-app.md](macos-app.md) | `zeldamac` and its self-test; the tvOS target's status |
| [distribution.md](distribution.md) | Getting a build onto a device, and why not TestFlight |
| [gotchas.md](gotchas.md) | Things that cost real time, and the measurement that settled each |

## Issue archive

[issues/](issues/) — the 28 tracked issues, one Markdown file each, with their
comments. They were kept in GitHub's issue tracker until the repository was
prepared for publication; the files are now the record, so a clone carries the
project's roadmap and its reasoning rather than pointing at a server.

## Reference material

`nesrun mapcheck` scores a rendered screen against a complete First Quest
overworld map. **That map is not in the repository** — it is assembled from the
game's own graphics and carries Nintendo's copyright notice in the image, so it
is supplied locally like the ROM is. `Reference/*.png` is gitignored.

The one used here is by Rick N. Bruns (NESMaps.com). Any map of the same
geometry works; the dimensions `mapcheck` expects are in
[agent-harness.md](agent-harness.md#overworld-reference-map).
