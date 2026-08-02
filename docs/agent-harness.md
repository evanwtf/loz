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

All fourteen take the ROM path as their second argument. `nesrun` with no
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
| `clearroom` | Fight the current room empty, then collect the drop |
| `oam` | List the actors on screen — Link, enemies, items — with positions |
| `ramdiff --control C` | Which RAM addresses an event moved — see below |
| `paltrace` | Log every write reaching palette memory |
| `embed` | Emit the ROM as Swift source ([rom-free.md](rom-free.md)) |

## Fighting: a loop, not a script

A replayed script works for walking across static geometry and fails
immediately in combat, because enemies move. Standing in a corner swinging
killed one Keese and then waited out ninety swings while the other two drifted
to the far wall; a fixed script has no way to notice that.

`clearroom` closes the loop. Every eight frames it walks at the nearest actor
and swings when in range:

```sh
swift run -c release nesrun clearroom zelda.nes \
  --load-state /tmp/r72.state --input "left:40" --save-state /tmp/cleared.state
# CLEARED in 350 frames, 6 swings, 14 pickups, 1 hits taken, 0 enemies left  screen $72
```

Compare that with the blind version: 90 swings for one kill, and a second
attempt that got Link killed.

### Two sources, two questions

The loop reads RAM and OAM for different things, and mixing them up is a bug:

| Question | Source | Why not the other one |
|---|---|---|
| How many enemies are left? | `enemyTypes` (`$0350`) | OAM undercounts — see below |
| Where do I swing? | OAM | The slot table has type, not position |

**OAM undercounts a room.** In Level 1 room `$63`, `oam` reported two Stalfos
while `$0350-$0352` held three: the third was live but had not been drawn yet.
Across one full run of that room the two disagreed on 8 of 29 decision ticks.
Counting sprites can therefore end a fight early, which is why the termination
test reads the slot table.

The opposite risk comes with it. The slot table is *empty* for about 24 frames
after a room loads, so a loop that trusted its first reading would call every
room clear on arrival. `RoomClearMonitor` handles both directions: it waits out
a spawn grace before an empty table is allowed to mean "there were never any",
and requires six consecutive empty ticks before declaring a clear. An enemy the
game knows about but has not drawn cannot be aimed at, so the loop simply waits
a tick for it to appear.

Two further distinctions the loop depends on, both learned the hard way:

- **Status bar sprites are not actors.** Hearts and item icons live above the
  playfield and were being targeted as enemies.
- **One sprite is an item, two is an enemy.** Zelda runs the PPU in 8x16 sprite
  mode, so actors are sprite pairs and floor pickups are singles. Before that
  distinction existed, a dropped key counted as an enemy that would not die:
  552 swings and 6000 frames spent attacking something Link only had to stand
  on.

`oam` prints the same classification as a one-off, which is the fastest way to
answer "what is actually on this screen" without a screenshot.

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

## Committed routes

Routes are expensive to derive and trivial to lose, so they live in
`docs/scripts/` as input scripts rather than as snapshots. Each one chains from
the previous, carries a `#` header saying what it starts from and which RAM
address proves it worked, and can be replayed from a clean checkout:

```sh
nesrun play zelda.nes --input "$(cat docs/scripts/boot-to-overworld.txt)" \
  --save-state /tmp/ow.state
nesrun play zelda.nes --load-state /tmp/ow.state \
  --input "$(cat docs/scripts/sword.txt)" --save-state /tmp/sword.state
nesrun play zelda.nes --load-state /tmp/sword.state \
  --input "$(cat docs/scripts/to-level1.txt)" --save-state /tmp/level1.state
```

| Script | Achieves | Proof |
|---|---|---|
| `boot-to-overworld.txt` | Past the title and registration to screen `$77` | `$00EB = 77` |
| `sword.txt` | The wooden sword from the cave on the starting screen | `$0657 = 01` |
| `to-level1.txt` | Overworld to Level 1, and in through the door | `$00EB = 73` |

Three things these routes had to work around:

- **Caves do not change `$00EB`.** It stays `$77` through the whole sword
  detour, so the item byte is the only proof anything happened.
- **Link is often boxed in by bushes**, and a blocked sideways move looks
  nothing like an overshoot: every candidate in a sweep returns the *identical*
  end position. Step up first, then sideways.
- **Settle frames before snapshotting are load-bearing.** `$00EB` updates
  during the scroll, so a state captured immediately after a screen change
  records the previous screen. A snapshot that claimed `$38` behaved like `$48`
  until `wait:90` was added.

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

## Finding RAM addresses

```sh
nesrun ramdiff zelda.nes --before A.state --after B.state --control C.state
```

Snapshot, do the thing, snapshot again, and the difference is a candidate list.
The catch is that the raw difference is unusable: between two states a few
hundred frames apart, **hundreds of bytes have moved** — RNG, animation
counters, sprite scratch, scroll state — and the signal is a byte or two wide.

`--control` is what makes it readable. Run a second sequence of comparable
length in which the event did *not* happen; anything that moved there moves on
its own, and is subtracted.

The best control is the same script with only the event removed. For the sword:

```sh
# the real route
nesrun play $R --load-state overworld.state \
  --input "$(cat docs/scripts/sword.txt)" --save-state sword.state

# identical, except `up:70` (which touches the sword) becomes `wait:70`
nesrun play $R --load-state overworld.state \
  --input "left:42,up:160,wait:260,right:6,wait:70,wait:60,down:150,down:100,right:60" \
  --save-state nosword.state

nesrun ramdiff $R --before overworld.state --after sword.state --control nosword.state
```

```
177 bytes changed, 164 also changed in the control run -> 13 candidates

  $0008  7F -> 0F
  ...
  $0657  00 -> 01  [0->1]
  $06F6  00 -> 10
```

Thirteen lines instead of a hundred and seventy-seven, and `[0->1]` flags the
shape most searches are looking for — a flag going from "don't have it" to
"have it". `$0657` is the sword, and it is now in `Zelda.symbols`.

### Finding an array rather than a byte

A control run is the wrong instrument when the thing you are looking for is a
*slot table*. Enemies move constantly, so anything holding their state also
changes in the control and gets subtracted away — the useful signal is
suppressed along with the noise.

Look for structure instead. Snapshot a room with enemies alive, clear it, and
search for a contiguous run that went non-zero to zero:

```
$0350-$0352  (3)  alive ['1B', '1B', '1B']
```

Three enemies, three bytes, one value each. Confirmed by repeating it in a
different room: three Stalfos in `$63` read `2A 2A 2A`, so the value is the
enemy *type* and the index is the slot. That is `enemyTypes` in `Zelda.symbols`.

Worth noting what this beats: `oam` reported only two of those three Stalfos,
because the third had not been drawn yet. Sprite counting undercounts a room;
the slot table does not.

Two things worth knowing before trusting a result:

- **A poor control is worse than none.** Combat is nondeterministic, so
  "fight the room" against "wait the same number of frames" leaves a lot of
  noise standing. Match the control to the run as closely as the event allows.
- **Session state and save state are different addresses.** `--no-prg-ram`
  restricts the search to `$0000-$07FF`; leaving PRG-RAM in is how you find
  where an item is *persisted* rather than where it is cached for this session.
  Confusing the two produces a symbol that works until you reload.

## Overworld reference map

`mapcheck` needs a complete First Quest overworld map at
`Reference/overworld-first-quest.png`.

**It is not committed.** The map is assembled from the game's own graphics and
has Nintendo's copyright notice rendered into the image, so it is supplied
locally exactly like the ROM is — `Reference/*.png` is gitignored. The one used
here is by Rick N. Bruns (NESMaps.com); any map matching the geometry below
works, and `--map` points at it anywhere.

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
