# Getting a build onto a device

Four ways to install this app, in increasing order of how much Apple is
involved. The right one depends on whose phone it is and whether you are
sitting next to it.

| Route | Needs | Apple sees | Expires |
|---|---|---|---|
| Simulator | Nothing | Nothing | Never |
| Direct install (cable or Wi-Fi) | Your Mac paired to the device | Nothing | With the profile |
| **Ad hoc** | The device's UDID registered | The UDID only | 1 year (paid), 7 days (free) |
| TestFlight / App Store | An upload | **The whole binary** | — |

The last row is the one to think about before using, and it is covered at the
bottom.

## Signing

The target is `wtf.evan.loz.zelda`, `CODE_SIGN_STYLE = Automatic`, deployment
target iOS 17. Set your team in the target's signing settings once and Xcode
handles the rest.

Which account you use decides how often the app dies on the device:

| Account | Profile lifetime | Registered devices |
|---|---|---|
| Free Apple ID | **7 days** | 3, and re-provisioning is manual |
| Paid Developer Program | 1 year | 100 per device class per year |

A free Apple ID is fine for your own phone and miserable for anyone else's — the
app stops launching after a week with an unhelpful error, and fixing it means
plugging into your Mac again.

## Simulator

```sh
xcodebuild -project Apps/ZeldaiOS.xcodeproj -scheme Zelda \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

xcrun simctl install "iPhone 17" \
  ~/Library/Developer/Xcode/DerivedData/ZeldaiOS-*/Build/Products/Debug-iphonesimulator/Zelda.app
xcrun simctl launch "iPhone 17" wtf.evan.loz.zelda -nesOrientation landscape
```

No signing at all. Good for layout and launch-option work, useless for anything
about touch latency or real frame pacing.

## Direct install to your own device

Building to a connected device from Xcode is the obvious path. The
command-line equivalent is worth knowing because it works **over Wi-Fi**, with
the phone in your pocket.

Find the device:

```sh
xcrun devicectl list devices
```

Build for the device, then install and launch:

```sh
xcodebuild -project Apps/ZeldaiOS.xcodeproj -scheme Zelda \
  -destination 'generic/platform=iOS' -configuration Debug build

xcrun devicectl device install app --device <identifier> \
  ~/Library/Developer/Xcode/DerivedData/ZeldaiOS-*/Build/Products/Debug-iphoneos/Zelda.app

xcrun devicectl device process launch --device <identifier> wtf.evan.loz.zelda
```

Three things learned doing this repeatedly:

- **Install works with the phone locked; launch does not.** A locked device
  fails with `FBSOpenApplicationErrorDomain … Locked`. Unlock it, then launch.
- **`devicectl` mis-parses launch arguments.** Passing `-nesDiagnostics 1`
  through `process launch` produced a timeout rather than the option taking
  effect. This is part of why diagnostics default to on — see
  [ios-app.md](ios-app.md#diagnostics-overlay).
- **Wi-Fi install is not slow.** For a build this size it is comparable to a
  cable and much less annoying.

Add `--console` to `process launch` to stream the unified log from the run.

## Ad hoc — someone else's device

This is the right route for a family member's phone. Nothing is uploaded to
Apple; you sign an `.ipa` against a profile that names specific devices, and
hand them the file.

1. **Get their UDID.** Settings → General → About → tap the serial number area,
   or plug the device into any Mac and read it from Finder. On a device you can
   pair, `xcrun devicectl list devices` shows it.
2. **Register it** at developer.apple.com → Certificates, Identifiers &
   Profiles → Devices. 100 iPhones per membership year; the count only resets
   when you renew.
3. **Create an Ad Hoc provisioning profile** for `wtf.evan.loz.zelda` that
   includes the device.
4. **Archive and export:**

   ```sh
   xcodebuild -project Apps/ZeldaiOS.xcodeproj -scheme Zelda \
     -destination 'generic/platform=iOS' -configuration Release \
     -archivePath build/Zelda.xcarchive archive

   xcodebuild -exportArchive -archivePath build/Zelda.xcarchive \
     -exportPath build/export -exportOptionsPlist ExportOptions.plist
   ```

   with `ExportOptions.plist`:

   ```xml
   <dict>
     <key>method</key>            <string>ad-hoc</string>
     <key>teamID</key>            <string>YOUR_TEAM_ID</string>
     <key>signingStyle</key>      <string>automatic</string>
     <key>compileBitcode</key>    <false/>
   </dict>
   ```

5. **Deliver it.** AirDrop the `.ipa` and open it, or use Apple Configurator.
   iOS will not install an `.ipa` from Mail or Messages.

**No App Review is involved and nothing is uploaded.** Apple issues the profile
and knows the UDIDs you registered; it never receives the binary.

The renewal is the part that bites: the profile expires a year out, and the app
simply stops launching. Rebuild and redeliver before then. A restored or
replaced phone is a new UDID and needs registering again.

## TestFlight and the App Store

Both would work technically. Neither should be used with a build produced by
`nesrun embed`.

The problem is not review — it is upload. **The cartridge is compiled into the
binary.** Pushing that build to App Store Connect puts Nintendo's game on
Apple's servers under your developer account, whether or not a human ever looks
at it:

| | Uploaded to Apple | Human review |
|---|---|---|
| Ad hoc | No | No |
| TestFlight, internal | **Yes** | No |
| TestFlight, external | **Yes** | Yes — Beta App Review |
| App Store | **Yes** | Yes |

Internal TestFlight avoids review but not the upload, so it does not solve
anything here.

App Store guideline 4.7 permits emulators; it does not permit shipping
commercial ROMs inside them. And this project's own position, stated at the top
of `CLAUDE.md`, is **not for the App Store** — the cartridge is yours, the
distribution rights are not.

### The ROM-free way out

If a build genuinely needs to be handed around, ship one without the game in it.
`embeddedROM` defaults to `nil`, `ZeldaROMData.swift` is generated and
gitignored, and `GameLauncher` already falls back to loading a `.nes` from disk —
so **a clean checkout builds an app with no cartridge in it at all.** The
recipient supplies their own dump.

That changes the calculus completely, since the binary then contains only code
you wrote. See [rom-free.md](rom-free.md) for what is still missing before the
app is presentable in that state.

## What CI does

`.github/workflows/ci.yml` builds the iOS app for the simulator on every push,
as a compile gate only — nothing is signed, archived, or distributed. It stages
a ROM from `$HOME/roms/zelda.nes` if the runner happens to have one, and builds
without it otherwise.
