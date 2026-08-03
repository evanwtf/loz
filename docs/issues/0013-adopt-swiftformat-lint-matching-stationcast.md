# #13 — Adopt swiftformat lint, matching StationCast

| | |
|---|---|
| **State** | closed |
| **Labels** | tooling |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

Add a `.swiftformat` config and run `swiftformat --lint` in CI, mirroring the convention already used in StationCast.

```sh
swiftformat Sources Tests --lint --cache ignore
```

Should land before the codebase grows much further, so the reformat diff stays small.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Done. `.swiftformat` is committed — deliberately close to defaults, with `consecutiveSpaces`, `wrap`, and `wrapArguments` disabled so the opcode table, NES palette, and APU period tables keep their aligned grids (a shifted row in a 256-entry table has to stay visible by eye).

CI runs `swiftformat Sources Tests --lint --cache ignore` as its own job, and prints the swiftformat version first so a failure caused by a tool upgrade introducing new rules doesn't look like a code regression.

Currently 0/56 files require formatting.
