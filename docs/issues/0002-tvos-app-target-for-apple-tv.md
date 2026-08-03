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


---

## Note

The iCloud save sync from [#30](0030-investigate-storing-savegames-state-in-icloud.md)
is a prerequisite rather than a companion. tvOS gives apps no guaranteed
persistent local storage — the Documents directory can be purged whenever the
system wants space — so without syncing, an Apple TV build would appear to save
and then silently lose progress at an arbitrary later date. That is worse than
not saving at all.

That work is done, and the tvOS target carries the same entitlement with the
same pinned key-value identifier as the phone, so the two share one quest.
