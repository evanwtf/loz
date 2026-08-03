# Adding a game

One app = one game, but nothing is forked. Adding Super Mario Bros. 3 means a
new game target, possibly a new mapper, and a thin app target.

## 1. Check the mapper

```sh
swift run nesrun info smb3.nes
```

If the reported mapper is not implemented, add it first — see
[emulator-mappers.md](emulator-mappers.md). SMB3 needs MMC3
([#11](issues/0011-mmc3-mapper-to-support-super-mario-bros-3.md)).

## 2. Get the ROM hash

```sh
swift run nesrun hash smb3.nes
```

## 3. Write the game definition

`Sources/SMB3Game/SMB3.swift`:

```swift
import NESCore

public enum SMB3: GameDefinition {
    public static let title = "Super Mario Bros. 3"
    public static let romResourceName = "smb3"
    public static let expectedMapper = 4
    public static let expectedROMHash = "<from nesrun hash>"

    public static let symbols = SymbolMap([:])
    public static let nativeRoutines = RoutineTable()
}
```

`symbols` and `nativeRoutines` have empty defaults, so a new game starts as a
plain emulated title and gains native routines over time — exactly the same path
Zelda is on.

## 4. Register the target

`Package.swift`:

```swift
.library(name: "SMB3Game", targets: ["SMB3Game"]),
...
.target(name: "SMB3Game", dependencies: ["NESCore"]),
```

## 5. Add the app target

Copy `Apps/ZeldaiOS/`, then change:

- The `GameDefinition` passed to `EmulatorHost`
- Bundle identifier and display name
- The bundled ROM resource
- App icon

The app file itself is only a few lines — everything real lives in `NESPlayer`:

```swift
@main
struct SMB3App: App {
    var body: some Scene {
        WindowGroup {
            GameLauncher(game: SMB3.self)
        }
    }
}
```

## What you should *not* need to touch

If adding a game requires changes to `NESCore` beyond a mapper, or any change to
`NESPlayer`, that is a signal the abstraction has leaked. The intended surface
is:

| Layer | Changes per game? |
|---|---|
| `NESCore` | Only a new mapper, if the board is unsupported |
| `NESPlayer` | Never |
| `NESAnalysis` | Never |
| `<Game>Game` | The whole point |
| App target | Thin: identity, icon, ROM |

## Per-game control tweaks

Games want different button layouts — SMB3 wants B as run and A as jump, sitting
comfortably under the thumb; Zelda wants sword and item. `GameDefinition` is the
right place to express that if it becomes necessary; `NESPlayer` should read it
rather than special-casing titles.
