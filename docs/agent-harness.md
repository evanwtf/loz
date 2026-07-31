# Agent harness

`nesrun` drives the game without a human: scripted input, PNG output, resumable
snapshots, pathfinding, and audio capture. It exists so an agent can explore the
world and check that things actually work.

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

## Commands

All twelve take the ROM path as their second argument. `nesrun` with no
arguments prints the full flag list for each.

| Command | Purpose |
|---|---|
| `info` | Cartridge geometry and interrupt vectors |
| `hash` | SHA-256, for pinning a `GameDefinition` |
| `analyze` | Static code/data analysis, split by confidence |
| `disasm --bank N` | Annotated listing for one 16KB bank |
| `run --frames N` | Boot headlessly and dump the framebuffer |
| `play` | Scripted input, screenshots, snapshots, tracing |
| `probe --inputs P` | Many candidate scripts in one process — see below |
| `navigate --to XX` | Pathfind to an overworld screen |
| `mapcheck` | Score a rendered screen against the reference map |
| `audio --seconds N` | Render the APU to a WAV with signal statistics |
| `paltrace` | Log every write reaching palette memory |
| `embed` | Emit the ROM as Swift source ([rom-free.md](rom-free.md)) |

## Probing: many guesses, one process

Working out an unknown route by launching `play` per guess is dominated by
process start and ROM load, and costs a round trip per answer. `probe` restores
the same snapshot for each candidate in one process, so a dozen guesses is one
command and one table:

```sh
swift run -c release nesrun probe zelda.nes \
  --load-state /tmp/room.state \
  --inputs "right:{0..24/4},up:200" \
  --goal 00EB=63 --watch 0070,0084 --save-state /tmp/next.state
```

`--inputs` expands braces — `{0..24/4}` is a stepped range, `{a,b,start}` is a
list, and multiple groups expand as a product. `--goal ADDR=VAL` marks success
in hex and `--save-state` replays the first winner so a successful probe leaves
a snapshot to continue from rather than needing a re-run.

Reach for this before writing a loop that shells out. It is the difference
between exploring a screen in seconds and in minutes.

## Input scripts

Comma-separated `buttons:frames` segments. Combine simultaneous buttons with
`+`; `wait` holds nothing.

```
wait:60,start:4,up+a:12,right:150
```

Buttons: `up down left right a b start select wait`.

## Navigating

`navigate` breadth-first searches over overworld screens by actually driving the
game and reading `$00EB`, so routes are discovered rather than hand-written.

```sh
swift run -c release nesrun navigate zelda.nes \
  --load-state /tmp/overworld.state --to 37 --save-state /tmp/level1.state
```

Two things this had to solve, both non-obvious:

- **Link dies.** He starts unarmed, and Octoroks killed him mid-search, freezing
  every branch as a dead end. Health is topped up during exploration.
- **Straight pushes almost never work.** Screen gaps are about a tile wide — on
  screen `$67`, moving up 80 frames then left escapes, but 70 or 100 do not. So
  the search *sweeps*: it holds the target direction while oscillating
  perpendicular, letting Link slide along the wall into whatever gap exists. One
  sweep per direction covers every offset.

The same sweep trick is what gets Link through dungeon doorways, which sit at
fixed positions in each wall.

## Known route to Level 1

```
$77 start -> $78 -> $58 -> $48 -> $28 -> $38
$38 is water with one narrow bridge: down:100, then left:300 reaches $37
$37 is the Level 1 entrance: right:12, up:140 goes in
```

Inside a dungeon, `$00EB` becomes the room number instead of the overworld
screen. Level 1's entrance room is `$73`.

## Menu navigation

Non-obvious, and worth writing down because it cost real time to derive:

| Screen | Behaviour |
|---|---|
| Title | `start` advances to file select |
| File select | `start` on "REGISTER YOUR NAME" opens registration |
| Registration | **d-pad moves the letter grid**, `a` types the highlighted letter |
| Registration | **`select` moves the heart cursor** between file rows |
| Registration | `REGISTER` / `END` is one row — `left`/`right` picks between them |
| Registration | `start` acts as Enter/confirm |
| File select | `start` begins the game on the highlighted file |

## Useful flags

| Flag | Purpose |
|---|---|
| `--filmstrip <dir> --every <n>` | PNG every n frames — the fastest way to see where a sequence goes wrong |
| `--watch <hex addrs>` | Print RAM bytes at the end, e.g. `--watch 00EB,0070` |
| `--trace` | Record executed code and report coverage against static analysis |
| `--trace-in` / `--trace-out` | Merge coverage across sessions |
| `--native` | Install decompiled Swift routines and report their call counts |
| `--scale <n>` | Screenshot scale; 2–3 keeps pixel art legible |

## Finding RAM addresses

The reliable method needs no prior knowledge: **snapshot, perform a known
action, snapshot again, diff**.

```sh
nesrun play zelda.nes --load-state a.state --input "right:200" --save-state b.state
# then diff the `ram` arrays in the two JSON files
```

Walking one screen east isolates the screen variable; taking damage isolates
health. Everything in `Zelda.symbols` was found this way.

## Audio

```sh
swift run -c release nesrun audio zelda.nes --seconds 12 --out title.wav
```

Reports peak, RMS, and zero-crossing rate. Those statistics are the quickest
check that the APU is producing music rather than silence or a DC offset — the
first run showed **zero crossings: 0**, which is exactly what a constant DC
level looks like and nothing like audio.

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

`$00EB` encodes the screen as `(row << 4) | col`, so a screen number maps
straight onto a crop. Cropping the map is how the Level 1 route above was
confirmed before spending any emulator time on it.

## Automated visual checking

`mapcheck` compares a rendered overworld screen against the reference map:

```sh
swift run -c release nesrun mapcheck zelda.nes --load-state /tmp/ow.state
# screen $77 (col 7, row 7)  structural correlation 0.999  [PASS]
```

It cannot be a pixel comparison — the reference has no Link, no enemies, and a
different palette table. Instead both images are reduced to a grid of block
luminances and correlated, so terrain layout dominates and sprites do not.

Measured on five screens: **0.949 to 0.999**.

One caveat learned the hard way. Screen `$38` initially scored **0.404**, which
looked exactly like a rendering bug — until walking Link a little further showed
the bridge, statue, and enemies all rendering correctly. `navigate` snapshots on
arrival, sometimes mid-scroll, and sampling too early captures a composite of
two screens. Hence the generous `--settle` default of 90 frames.

Correlation is also unreliable on low-variance screens (large uniform water or
darkness), where there is little structure to correlate. Treat a single low
score as a prompt to look, not as proof of a defect.
