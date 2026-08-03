# #1 — iOS app target: runnable Zelda on device

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

Build the iOS app target so the game runs on a real iPhone, launching straight into Zelda with no ROM picker.

The reusable shell already exists in `Sources/NESPlayer` (`EmulatorHost`, `GameScreen`, `TouchControls`, `GameControllerSupport`). What is missing is the app target itself.

**Work**
- `Apps/ZeldaiOS/` with `@main` App, Info.plist, asset catalog, app icon
- `.xcodeproj` using a `PBXFileSystemSynchronizedRootGroup` so adding Swift files later never requires touching `project.pbxproj`
- Local Swift package dependency on `NESCore`, `NESPlayer`, `ZeldaGame`
- ROM embedded as a bundle resource, validated against `Zelda.expectedROMHash` at launch
- Battery save persisted to Application Support

**Notes**
- Free provisioning expires every 7 days; a paid account gives 1 year
- The ROM is gitignored, so the build needs it supplied locally

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Done. iOS app builds and runs, launching straight into the game with no ROM picker.

- `Apps/ZeldaiOS.xcodeproj` with a file-system synchronized group, so adding Swift files (or the ROM) never touches `project.pbxproj`
- ROM validated against `Zelda.expectedROMHash` at launch, with a visible error rather than a black screen
- Both portrait and landscape playable
- Audio via AVAudioEngine
- Battery saves persisted to Application Support

One notable fix: Debug builds ran at **15 fps** because `NESCore` compiled `-Onone`. Building it at `-O` in Debug too gives 60 fps. Documented in `docs/ios-app.md` — without it, running from Xcode looks like a broken emulator.
