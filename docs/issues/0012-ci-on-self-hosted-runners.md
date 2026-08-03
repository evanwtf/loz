# #12 — CI on self-hosted runners

| | |
|---|---|
| **State** | closed |
| **Labels** | tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

Set up GitHub Actions using the org's self-hosted runners (this repo is under `evanwtf`).

**Jobs**
- Build + test the Swift package: `runs-on: [self-hosted, Linux, X64]` will not work here (Xcode/Apple SDKs needed), so use `runs-on: [self-hosted, macOS, ARM64]`
- `swift build && swift test` for NESCore/NESAnalysis
- `xcodebuild` for the app targets once they exist (#1-#3)
- `swiftformat --lint` (see #13)

**Constraint**: the ROM is gitignored and must not be committed, so any test that needs it has to be skipped in CI or driven by a synthetic cartridge. The existing unit tests already build synthetic ROMs in-memory and need no real ROM — keep it that way.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Done. `.github/workflows/ci.yml` runs three jobs, all on `[self-hosted, macOS, ARM64]`:

- **package** — `swift build`, `swift test`, `swift build -c release`, plus a `nesrun` CLI smoke test
- **lint** — `swiftformat --lint` (#13)
- **app** — `xcodebuild` for the iOS target, `CODE_SIGNING_ALLOWED=NO`

The ROM constraint holds: tests build synthetic iNES images in memory, the routine-equivalence tests skip themselves when `zelda.nes` is absent, and the app job stages a ROM only if the runner happens to have a local copy. CI passes on a clean checkout.

On `xcodebuild` for all of #1-#3: iOS is covered, macOS is covered by `swift build` since `zeldamac` is a SwiftPM executable rather than an Xcode project, and tvOS can't be built on this runner — the platform component isn't installed. That's tracked in #2.
