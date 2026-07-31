# Agent harness

`nesrun play` drives the game without a human: scripted input, PNG output, and
resumable snapshots. It exists so an agent can walk around the world and check
that things look right.

## Why snapshots matter

Reaching Zelda's overworld costs ~520 frames of title screen, name
registration, and file selection before a single frame of gameplay runs. Doing
that for every investigation is intolerable. Capture the state once, then branch
from it:

```sh
# Once: boot to the overworld and snapshot.
swift run -c release nesrun play zelda.nes \
  --input "$(cat docs/scripts/boot-to-overworld.txt)" \
  --save-state /tmp/overworld.state

# Thereafter: resume instantly and try something.
swift run -c release nesrun play zelda.nes \
  --load-state /tmp/overworld.state \
  --input "right:150" --out /tmp/shot.png
```

Snapshots are gitignored: they embed CHR-RAM, which is game data. The input
script that regenerates them is committed instead, so the workflow is
reproducible without redistributing anything from the cartridge.

## Input scripts

Comma-separated `buttons:frames` segments. Combine simultaneous buttons with
`+`; `wait` holds nothing.

```
wait:60,start:4,up+a:12,right:150
```

Buttons: `up down left right a b start select wait`.

## Menu navigation

Non-obvious, and worth writing down because it cost real time to derive:

| Screen | Behaviour |
|---|---|
| Title | `start` advances to file select |
| File select | `start` on "REGISTER YOUR NAME" opens registration |
| Registration | **d-pad moves the letter grid**, `a` types the highlighted letter |
| Registration | **`select` moves the heart cursor** between file rows |
| Registration | The `REGISTER` / `END` row is one row — `left`/`right` picks between them |
| Registration | `start` acts as Enter/confirm |
| File select | `start` begins the game on the highlighted file |

## Useful flags

| Flag | Purpose |
|---|---|
| `--filmstrip <dir> --every <n>` | PNG every n frames — the fastest way to see where a sequence goes wrong |
| `--watch <hex addrs>` | Print RAM bytes at the end, e.g. `--watch 00EB,0070` |
| `--trace` | Record executed code and report bytes static analysis never found |
| `--scale <n>` | Screenshot scale; 2–3 keeps pixel art legible |

## Overworld reference map

`Reference/overworld-first-quest.png` is the complete First Quest overworld
(map by Rick N. Bruns, NESMaps.com).

Geometry, which makes it machine-checkable rather than just something to look at:

```
Full image      4352 x 1408
Legend panel    leftmost 256 px  (crop it off)
Map area        4096 x 1408  =  16 x 8 screens
One screen      256 x 176        (the play area; the HUD is a separate 256x64)
```

So overworld screen `(col, row)` occupies:

```
x = 256 + col * 256
y =       row * 176
```

That means a rendered play area can be compared directly against the
corresponding crop — the basis for automated visual checks as the decompilation
progresses. Expect palette and sprite differences: the reference has no Link,
no enemies, and was captured with a different palette table, so compare
structure rather than exact pixels.
