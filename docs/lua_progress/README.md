# Lua tracker: progress

Where the mGBA side stands. For the addresses see [../MEMORY_MAP.md](../MEMORY_MAP.md); for how they were found see [spike-log.md](spike-log.md); for the end-to-end design see [../../DESIGN.md](../../DESIGN.md).

## Done

**Battle tracking** (`lua/battle.lua`), confirmed in mGBA against real fights (trainer wins, a lost fight, wild faints):

| Event | Emitted when |
|-------|--------------|
| `kill` | an enemy mon faints in a trainer battle; credited to your mon on the field. Carries `split` (leaders defeated + 1), `trainer`, `key` (`<trainer>:<enemy party slot>`), `enemy`, and `ambiguous` in doubles |
| `death` | one of your mons faints in any battle (wild or trainer); sent when the battle ends, once per mon |
| `split` | a gym leader's flag is set after a battle; `badges` is how many of the eight leaders are defeated |

**Catches** (`lua/mons.lua`), confirmed in mGBA on a new game: starter Chimchar sent before the first battle, then six wild catches each sent when their battle ended, the last one (Skitty, with a full party) read from Box 1:

| Source | How |
|--------|-----|
| Wild / static catch | the battle ends with `gBattleOutcome = 7`; the enemy mon's personality + OT id is looked up in the party and boxes and read from there (final nickname). Retried for ~10 s if not stored or mid-rewrite |
| Starter (and any new own-OT mon outside battle) | party scan every 30 frames, out of battle only; a new mon must read the same with a valid checksum on two scans |
| Already there at start / after a load | recorded as known, not sent |

**Evolutions** (`lua/mons.lua`), from the same party scan: a known mon whose species differs from its last valid read, with the new species read the same with a valid checksum on two scans, sends `evolve {pid, from, to, nick?}`. `nick` is sent only when the game renamed the mon (it still had its species name). A change that keeps the species name is a form change and is only logged. Checked by running the tracker offline across the real Scatterbug → Spewpa savestates (`fixtures/private/r2-bag-before-candy.ss` → `r2-evolution-scene-spewpa.ss`, and → `r2-pokecenter-after-pc.ss` with the party reordered): one `evolve` each time. Confirmed live: Skitty → Delcatty with a Moon Stone (from the bag) sent one `evolve` with `nick: "Delcatty"`. A level-up evolution right after a battle is not tested live on purpose: Run & Bun runs level with the Endless Candy, so it rarely happens. The same scan would see it once the battle ends.

Supporting modules: `lua/gen3.lua` (party struct decoding, names, flags, play time, run id, ROM check), `lua/addresses.lua`, `lua/json.lua`, `lua/tracker.lua` (mGBA entry point: ROM check, play-time-jump reset, `EVENT {json}` console output).

**Tests:** `npm run test:lua`, 50 scenarios on a fake memory, no emulator needed. Several replay frame sequences logged from real fights. The fake memory models the GBA bus's rotated misaligned reads. The identity check, the per-slot dedupe and the trainer-bit check were each broken on purpose to confirm a test fails.

## Behavior worth knowing

- The enemy's `gBattleMons` slot is rewritten in pieces on a switch-in, so the tracker only counts an HP drop when the mon's identity is unchanged since the previous frame. Without this, the first Pineco/Clobbopus-style phantom kills appear.
- "Trainer battle" comes from `gBattleTypeFlags` bit 3. The opponent id is stale after a battle and is only used when that bit is set.
- Play-time jumps (loading a savestate or save) reset the battle tracker silently. There is no `sync` yet, so the sheet is not told.
- A faint is committed as a `death` when the battle ends. Run & Bun has no overworld fainting, so nothing else is needed.
- mGBA keeps `require`'s cache between script loads. `tracker.lua` clears its own modules on every load; loading a script does not unload an earlier one (its frame callback keeps running until mGBA restarts).

## Dev tool: driving mGBA from a script

`lua/dev/remote.lua` + `tools/remote.py` drive a running mGBA from a script (buttons, screenshots, savestates, per-frame watchers). See [../../tools/README.md](../../tools/README.md).

## Not done

- **Trades** (next): a new party mon with another OT id is only logged today.
- **`sync`**: snapshot (mons, defeated trainers, splits, play time) on script start and on any play-time discontinuity, so the sheet can reconcile after savestates.
- **Relay**: TCP socket from Lua, the local daemon with a disk-backed queue, `id` stamping. Events currently only print to the mGBA console.
- **Doubles credit**: `gBattlerAttacker` is not located, so doubles kills are credited to the leftmost live mon and flagged `ambiguous`.

## Not yet confirmed live

- A **gym leader win**. The leader ids (264-271) come from the trainer table, not from a fight. The first win should produce `kill … split: N` followed by `split {badges: N}`.
- **Double battles**: handled in code and in tests, never seen in play.
- A mid-battle faint followed by a **blackout** (whole party wiped) in a wild fight.
