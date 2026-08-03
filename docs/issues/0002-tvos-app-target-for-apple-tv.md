# #2 — tvOS app target for Apple TV

| | |
|---|---|
| **State** | open |
| **Labels** | enhancement, app |
| **Opened** | 2026-07-31 |
| **Closed** | — |
| **Author** | evandhoffman |

---

Apple TV target sharing `NESPlayer`.

**Work**
- `Apps/ZeldatvOS/` app target, top-shelf image, 1920x1080 layout
- Controller required — the Siri Remote is unusable for this game, so surface a clear 'connect a controller' state rather than failing silently
- Verify `GameControllerSupport` handles connect/disconnect mid-session
- Sideload from Xcode over the network

Blocked by nothing; `GameControllerSupport` already exists.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw
