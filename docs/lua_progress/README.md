# Lua tracker: progress

Where the mGBA side stands. For the addresses see [../MEMORY_MAP.md](../MEMORY_MAP.md); for how they were found see [spike-log.md](spike-log.md); for the end-to-end design see [../../DESIGN.md](../../DESIGN.md).

## Done

**Battle tracking** (`lua/battle.lua`), confirmed in mGBA against real fights (trainer wins, a lost fight, wild faints):

| Event | Emitted when |
|-------|--------------|
| `kill` | an enemy mon faints in a trainer battle; credited to your mon on the field. Carries `split` (leaders defeated + 1), `trainer`, `key` (`<trainer>:<enemy party slot>`), `enemy`, and `ambiguous` in doubles |
| `death` | one of your mons faints in any battle (wild or trainer); sent when the battle ends, once per mon |
| `split` | a gym leader's flag is set after a battle; `badges` is how many of the eight leaders are defeated |

Supporting modules: `lua/gen3.lua` (party struct decoding, names, flags, play time, run id, ROM check), `lua/addresses.lua`, `lua/json.lua`, `lua/tracker.lua` (mGBA entry point: ROM check, play-time-jump reset, `EVENT {json}` console output).

**Tests:** `npm run test:lua`, 23 scenarios on a fake memory, no emulator needed. Several replay frame sequences logged from real fights. The fake memory models the GBA bus's rotated misaligned reads. The identity check, the per-slot dedupe and the trainer-bit check were each broken on purpose to confirm a test fails.

## Behavior worth knowing

- The enemy's `gBattleMons` slot is rewritten in pieces on a switch-in, so the tracker only counts an HP drop when the mon's identity is unchanged since the previous frame. Without this, the first Pineco/Clobbopus-style phantom kills appear.
- "Trainer battle" comes from `gBattleTypeFlags` bit 3. The opponent id is stale after a battle and is only used when that bit is set.
- Play-time jumps (loading a savestate or save) reset the battle tracker silently. There is no `sync` yet, so the sheet is not told.
- A faint is committed as a `death` when the battle ends. Run & Bun has no overworld fainting, so nothing else is needed.
- mGBA keeps `require`'s cache between script loads. `tracker.lua` clears its own modules on every load; loading a script does not unload an earlier one (its frame callback keeps running until mGBA restarts).

## Not done

- **Captures** (next): scan party + PC boxes for new ids, debounced, with the met location from the game. Needs the PC box address (`gPokemonStorage`, unverified).
- **Evolutions**: same id, different species between scans.
- **Trades**: a tracked id replaced by an unknown id with a different OT in the same slot.
- **`sync`**: snapshot (mons, defeated trainers, splits, play time) on script start and on any play-time discontinuity, so the sheet can reconcile after savestates.
- **Relay**: TCP socket from Lua, the local daemon with a disk-backed queue, `id` stamping. Events currently only print to the mGBA console.
- **Doubles credit**: `gBattlerAttacker` is not located, so doubles kills are credited to the leftmost live mon and flagged `ambiguous`.

## Not yet confirmed live

- A **gym leader win**. The leader ids (264-271) come from the trainer table, not from a fight. The first win should produce `kill … split: N` followed by `split {badges: N}`.
- **Double battles**: handled in code and in tests, never seen in play.
- A mid-battle faint followed by a **blackout** (whole party wiped) in a wild fight.
