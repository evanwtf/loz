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
| [emulator-mappers.md](emulator-mappers.md) | MMC1, the `Mapper` protocol, adding MMC3 |
| [rom-format.md](rom-format.md) | iNES parsing and what Zelda's cartridge actually reports |

## Practice

| Document | What it covers |
|---|---|
| [testing.md](testing.md) | Test philosophy, what each suite guards, how to add more |
| [adding-a-game.md](adding-a-game.md) | Shipping a second title without forking anything |
| [ios-app.md](ios-app.md) | Building, running, and sideloading the app |

## Reference material

`Reference/overworld-first-quest.png` — complete First Quest overworld map by
Rick N. Bruns (NESMaps.com). Geometry and how to use it programmatically are
documented in [agent-harness.md](agent-harness.md#overworld-reference-map).
