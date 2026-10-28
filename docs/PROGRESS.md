# Progress

The design is in [DESIGN.md](DESIGN.md); the Lua tracker's behavior is in [lua_progress/README.md](lua_progress/README.md).

Legend: `[x]` done and checked, `[~]` done but only partly checked (noted), `[ ]` not started, `[-]` decided against (with the reason).
"Live" means confirmed in mGBA during play. "Dev sheet" means confirmed on the copy of the spreadsheet, not the real one.

```
mGBA (Lua tracker) ──NDJSON/TCP──▶ relay ──HTTPS──▶ Apps Script web app ──▶ Rankings sheet
   done                              done             done, on the real sheet
```

## Summary

| Area | State |
|------|-------|
| Game data (RAM / ROM map) | Party, battle, flags, names, PC boxes and screen ids found; catch and evolution behavior observed live. `gBattlerAttacker` found (live) |
| Lua tracker | Battles (kills, deaths, splits), catches (including the starter) and evolutions done and live. Output to the relay done, not yet live in mGBA. `sync` snapshot built, sent by hand. Trades not started |
| Relay | Done; tested with a fake web app, and once by hand end to end against the dev sheet |
| Apps Script / sheet | Web app, journal and reconcile done, tested on the dev sheet and deployed to the real one |
| Testing | Unit-style tests for the sheet, Lua and relay. Remote control for in-emulator checks exists; no automated end-to-end test |
| Rollout to the real sheet | Web app deployed; some splits played fully. Doesn't cover everything yet |

## 1. Game data (RAM / ROM)

Details: [MEMORY_MAP.md](MEMORY_MAP.md), method in [lua_progress/spike-log.md](lua_progress/spike-log.md).

- [x] Party, party count, enemy party, mon struct decode (live)
- [x] Save block pointers, play time, trainer id (live)
- [x] Battle state: `gMain.inBattle`, `gBattleTypeFlags`, `gBattleMons`, opponent trainer id, `gBattleOutcome` (live)
- [x] Trainer-defeated flags (live), RAM id ↔ `gTrainers` entry offset
- [x] ROM tables: species names, `gTrainers`, map section names (map names checked on savestates only)
- [x] PC boxes, vanilla layout (live)
- [x] `gMain.callback2` screen ids (overworld, bag, party menu, evolution, PC, battle) (live)
- [x] Catch, evolution and PC moves traced frame by frame (live)
- [x] `gBattlerAttacker`, to credit doubles kills exactly (live)
- [x] Gym leader ids confirmed against a real leader fight (live)
- Skipped on purpose: badge flags (the split comes from leader flags), `gBattlerPartyIndexes`

## 2. Lua tracker (`lua/`)

- [x] Entry point `tracker.lua`: ROM check, play-time-jump reset, `EVENT {json}` console output, event ids
  - [x] After a play-time jump the mon tracker waits 60 frames before reading what is already there: on a soft reset + Continue the party is copied in after the play time, and seeding at once sent a catch for every mon (seen live)
- [x] Battle tracker `battle.lua`
  - [x] `kill`: trainer battles only, credited to the mon on the field (live)
  - [x] `killedBy` (`attack` / `friendly fire` / `self inflicted`) and `fallback: "leftmost"` on kills; recorded in `_Events`, not used by the sheet
  - [x] `killedBy: "status"` (poison / burn damage at the end of the turn) on kills and deaths, from where the battle script is (`gBattlescriptCurrInstr`); burn, toxic and poison deaths seen live; an enemy kill by status is tests only
  - [ ] `killedBy` `hazard` / `weather`: separate battle scripts, not looked at yet; until then those KOs can read as `attack` and the like
  - [x] `death`: any battle, sent when it ends, once per mon (live, wild)
  - [x] `killedBy` on deaths: `attack` / `friendly fire` / `self inflicted` from `gBattlerAttacker` (tests only); `hazard` / `weather` as for kills
  - [x] `split`: gym leader flags set after a battle (live)
  - [x] Doubles: credited to `gBattlerAttacker` when it is one of yours (live); otherwise leftmost live mon, `ambiguous` flagged (tests only)
  - [ ] Blackout (whole party wiped) in a wild fight, not seen live
- [x] **Catches** (`mons.lua`): from the battle outcome, from the party or boxes, and the starter outside battle (live, including a catch with a full party that goes to a box)
  - [x] A temporary mon with your OT id written over an occupied party slot (Wally's catching tutorial puts a Zigzagoon in slot 0 for the whole scene) is not a catch; its arrival is seen live, the tracker fix is tests only
- [x] **Evolutions** (`mons.lua`): `evolve {pid, from, to, nick?}` (live). A level-up evolution right after a battle is skipped on purpose; runs level with the Endless Candy, so it rarely happens
- [ ] **Trades**: tracked id replaced by an unknown id with a different OT in the same slot. In Run & Bun gift mons come from NPC trades, so they always land in the party. To check on a real trade: the met location (vanilla uses 254, "in-game trade", which the map table doesn't cover) and the slot transition on the trade screen
- [x] **`sync` snapshot** (`sync.lua`): `syncToTracker()` from the scripting console sends every mon, defeated trainers, badges and play time. Manual only, by choice (never sent on a load)
- [x] **Help text**: loading `tracker.lua` adds an "Auto-tracker help text" buffer to the scripting window (what `syncToTracker()` is for, link to the README's how-to-use). Printed row by row, as a newline inside `print()` wraps the text at the wrong column
- [~] Output to the relay (`relay_client.lua`): TCP to the relay, reconnect on a timer, events dropped while disconnected. Tested on a fake of mGBA's socket API; not yet live in mGBA
- Not needed: new-run detection. Starting a new run is manual (Reset Run on the sheet)

## 3. Relay (`relay/relay.mjs`)

- [x] TCP server for the tracker's newline-delimited JSON
- [x] Best-effort queue: batches sent as independent requests, retried a few times, then dropped
- [x] HTTPS POST to the web app with the shared token, following the Apps Script redirect
- [x] Config from `.env`, start-up check of URL and token
- [x] Tests with a fake web app
- [x] End to end by hand against the dev sheet over TCP

## 4. Apps Script / sheet (`appsscript/`)

Tested on the **dev copy**; the web app is also deployed to the real sheet.

- [x] `Rankings.js` helpers shared by the manual buttons and the web app
- [x] Web app `doPost` / `doGet`: token check, lock, idempotency by event id, run mismatch held
- [x] Events: `catch`, `kill`, `death`, `evolve`, `trade`, `split`, `sync`
- [x] Journal in hidden `_Events`, issues in `_Issues`
- [x] `sync` reconcile: rewind, forward jump, killer re-attribution, adds missing mons
- [~] `sync` writes species, nicknames and missing mons in bulk (a column or block per write, not a call per mon), falling back to one mon at a time if the sheet rejects the write. Seen working on the dev sheet by eye; the sheet scenarios were not re-run after the fallback and the `Venonat` change
- [x] Undo latest tracking change button
- [x] Dev-only `dump` / `reset` / `undo` actions (refuse unless `ENV=dev`)
- [-] Event for a mon that vanishes from party and boxes (`missing`): not needed, `sync` covers it
- [-] "Resync" sheet menu item: not needed, the relay never writes back so the sheet can't ask the tracker, and `syncToTracker()` in the mGBA console already does it by hand
- [-] Use the `ambiguous` flag (and `killedBy` / `fallback`) on kills in the sheet: not needed, they are recorded in `_Events` with the event and the sheet doesn't act on them
- [ ] Known limit: one enemy mon's credit across two jumped-between timelines goes to the most recent killer

## 5. Testing and tooling

- [x] Sheet tests against the dev web app (`npm run test:sheet`)
- [x] Lua tests on a fake memory, no emulator (`npm run test:lua`), covering catches, evolutions and `sync`
- [x] Relay tests, no network (`npm run test:relay`)
- [x] `setup-clasp`, `gen-token`, `deploy`, `deploy:dev`
- [x] Read-only probes `lua/spike/probe.lua`, `probe2.lua`
- [x] Remote control `lua/dev/remote.lua` + `tools/remote.py`: buttons, screenshots, savestates and watchers from a script (live)
- [ ] Tests for trades, as they are written
- [-] Emulator-in-the-loop test: not needed, it would mean running mGBA, and a person can load a state and check by hand
- [~] End-to-end: Lua output → relay → dev web app → sheet, run once by hand (not automated; the Lua part on fake memory and a fake socket)
- [-] `tools/replay.py` to post recorded event streams: not needed, nothing records events to a file, and `tests/sheet/run.mjs` and `sim.mjs` already post hand-written sequences

## 6. Rollout to the real sheet

- [x] Deploy the web app to the real sheet (`clasp` prod file, Script Properties `TOKEN`, no `ENV=dev`) and approve its permissions once
- [x] Run with the relay against the real sheet for a few battles; compare with manual counts
- [x] Decided how to start a new run: press Reset Run; the first event after it sets the new run
- [~] Play a full split live and fix attribution problems: some splits played fully; it doesn't cover everything yet

## 7. Docs

- [x] README, MEMORY_MAP, lua_progress, DESIGN.md, relay section

## Next

1. **Trades** (same party scan as evolutions)
2. Polish
