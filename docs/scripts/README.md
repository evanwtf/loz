# Route scripts

Input scripts that reproduce known game states, so nobody has to derive them
twice. Snapshots are gitignored — they embed CHR-RAM, which is cartridge data —
so the script that regenerates a state is committed instead of the state.

Each script starts from the state the previous one leaves, carries a `#` header
saying what it starts from and which RAM address proves it worked, and is
replayed with `--input "$(cat …)"`. Comments and line breaks are stripped by
the parser.

## The chain

| Script | Achieves | Proof |
|---|---|---|
| `boot-to-overworld.txt` | Past the title and registration to the starting screen | `$00EB = 77` |
| `sword.txt` | The wooden sword from the cave on that screen | `$0657 = 01` |
| `to-level1.txt` | Overworld to Level 1 and in through the door | `$00EB = 73` |
| `level1-key-room.txt` | West into the key room | `$00EB = 72` |
| *(`clearroom`)* | Kill the three Keese and collect the key | `$066E = 01` |
| `level1-locked-door.txt` | Back east, then north through the locked door | `$00EB = 63`, `$066E = 00` |

## Running it

```sh
R=zelda.nes; S=/tmp/loz
mkdir -p $S
run() { swift run -c release nesrun play $R --load-state "$1" \
          --input "$(cat docs/scripts/$2)" --save-state "$3"; }

swift run -c release nesrun play $R \
  --input "$(cat docs/scripts/boot-to-overworld.txt)" --save-state $S/overworld.state
run $S/overworld.state sword.txt          $S/sword.state
run $S/sword.state     to-level1.txt      $S/level1.state
run $S/level1.state    level1-key-room.txt $S/r72.state

# Combat is a closed loop, not a script: enemies move, so there is nothing to
# replay. `clearroom` reads OAM each tick and fights until the room is empty,
# then walks onto whatever dropped.
swift run -c release nesrun clearroom $R --load-state $S/r72.state \
  --input "left:40" --max-frames 6000 --save-state $S/r72-key.state

run $S/r72-key.state level1-locked-door.txt $S/r63.state
```

## Why some legs are scripts and some are not

Walking across static geometry is deterministic, so a fixed script is the right
tool and the cheapest thing to replay. Combat is not: a script that killed three
Keese once will miss them entirely on the next run, because they are somewhere
else. Anything involving enemies belongs to `clearroom`.

## What these routes cost to find

Worth knowing before deriving a new one, because each of these looked like a
different problem at first:

- **A blocked move and an overshoot look nothing alike.** When a sweep returns
  the *identical* end position for every candidate, the input is doing nothing
  at all — Link is boxed in, usually by bushes on the overworld or by a doorway
  tunnel in a dungeon. Move on the other axis first.
- **Dungeon doors have alignment windows about six frames wide.** The overworld
  is forgiving; dungeons are not.
- **Settle before snapshotting.** `$00EB` updates during the scroll, so a state
  captured immediately after a screen change records the *previous* screen.
- **Caves do not change `$00EB` at all.** The sword detour stays on `$77` from
  start to finish; only `$0657` proves it happened.
- **Room numbers are `(row << 4) | col`,** the same as overworld screens. `$72`
  and `$63` are not adjacent, which rules out a whole class of guesses before
  any are tried.
