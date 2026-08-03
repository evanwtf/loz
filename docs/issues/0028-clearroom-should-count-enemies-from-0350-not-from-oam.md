# #28 — clearroom should count enemies from $0350, not from OAM

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, tooling |
| **Opened** | 2026-08-02 |
| **Closed** | 2026-08-02 |
| **Author** | evandhoffman |

---

Found while closing #23.

`clearroom` decides a room is empty by clustering OAM into entities and checking that none are left. That undercounts: in room `$63`, `oam` reported **two** Stalfos while `$0350-$0352` held **three**. The third existed but had not been drawn yet.

`enemyTypes` (`$0350`) is now in `Zelda.symbols` and is the correct signal — one byte of type per slot, zero when empty, populated before the sprite appears.

**Work**

- Count live slots at `$0350` instead of clustering OAM for the termination test
- Keep OAM for *targeting* — it is what says where to swing, and the slot table does not carry position
- Re-run the `docs/scripts/` chain to confirm no route regresses

**Why it has not bitten yet.** `clearroom` walks for pickups after it believes the room is clear, which absorbs a premature exit. So this is latent rather than broken — worth fixing before anything depends on the clear signal being exact, which #24 will.

Not urgent, but it is a correctness bug in a loop that is about to get more use.
