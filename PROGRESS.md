# Progress

Last updated 2026-10-12. The design is in [DESIGN.md](DESIGN.md); the Lua details are in [docs/lua_progress/](docs/lua_progress/README.md).

Legend: `[x]` done and checked, `[~]` done but only partly checked (noted), `[ ]` not started.
"Live" means confirmed in mGBA during play. "Dev sheet" means confirmed on the copy of the spreadsheet, not the real one.

```
mGBA (Lua tracker) ──NDJSON/TCP──▶ relay ──HTTPS──▶ Apps Script web app ──▶ Rankings sheet
   done                              done             done on dev copy
```

## Summary

| Area | State |
|------|-------|
| Game data (RAM / ROM map) | Party, battle, flags, names, PC boxes and screen ids found; catch and evolution behavior observed live. Doubles attacker still open |
| Lua tracker | Battles (kills, deaths, splits) and catches including the starter done and live. Evolutions done and live. Output to the relay done (not yet live in mGBA). Trades, `sync` not started |
| Relay | Done (TCP, best effort, nothing stored); tested with a fake web app, and once by hand end to end against the dev sheet |
| Apps Script / sheet | Web app, journal and reconcile done and tested on the dev sheet. Not on the real sheet |
| Testing | Sheet tests (18), Lua tests (55) and relay tests (12) pass. Remote control for in-emulator checks exists; no automated emulator-in-the-loop or end-to-end test |
| Rollout to the real sheet | Not started |

## 1. Game data (RAM / ROM)

Details: [docs/MEMORY_MAP.md](docs/MEMORY_MAP.md), method in [docs/lua_progress/spike-log.md](docs/lua_progress/spike-log.md).

- [x] Party, party count, enemy party, mon struct decode (live)
- [x] Save block pointers, play time, trainer id (live)
- [x] `gMain.inBattle`, `gBattleTypeFlags`, `gBattleMons` and its fields, opponent trainer id (live)
- [x] Trainer-defeated flags (live), RAM id ↔ `gTrainers` entry offset (four trainers)
- [x] ROM tables: species names, `gTrainers`, map section names (map names checked on savestates only)
- [x] PC boxes: `gPokemonStoragePtr` `0x03005da4` → `0x02028848`, vanilla layout (live)
- [x] `gMain.callback2` screen ids (overworld, bag, party menu, evolution, PC, battle) (live)
- [x] Catch, evolution and PC moves traced frame by frame: in-place decryption makes a failed-checksum frame, party count goes stale, party compacts, mons are briefly in neither party nor box (live)
- [ ] `gBattlerAttacker`, to credit doubles kills exactly
- [ ] Gym leader ids confirmed against a real leader fight (derived from the table so far)
- [x] `gBattleOutcome` `0x02023716`: won 1, ran 4, caught 7; kept after the battle (live + savestates)
- Skipped on purpose: badge flags (the split comes from leader flags), `gBattlerPartyIndexes`

## 2. Lua tracker (`lua/`)

- [x] Entry point `tracker.lua`: ROM check, play-time-jump reset, `EVENT {json}` console output, event ids
- [x] `gen3.lua`, `addresses.lua`, `json.lua`
- [x] Battle tracker `battle.lua`
  - [x] `kill`: trainer battles only, credited to the mon on the field, identity check against switch-in glitches, one credit per enemy slot (live)
  - [x] `death`: any battle, sent when it ends, once per mon (live, wild)
  - [x] `split`: gym leader flags set after a battle (tests only; no leader win seen live yet)
  - [~] Doubles: leftmost live mon credited, `ambiguous` flagged (tests only)
  - [ ] Blackout (whole party wiped) in a wild fight, not seen live
- [x] **Catches** (`mons.lua`): battle ends with outcome caught → the mon is looked up in party / boxes; outside battle a new own-OT party mon read the same on two scans with a valid checksum (the starter). Mons present at start or after a load are known, not sent (live: new game → starter Chimchar sent before the first battle, then a wild Starly on Route 102 sent when the battle ended)
  - [x] A catch with a full party goes to a box and is sent from there (live: Skitty as the seventh mon)
- [x] **Evolutions** (`mons.lua`): a known party mon with a new species, read the same with a valid checksum on two scans → `evolve {pid, from, to, nick?}`; `nick` only when the game renamed it. Same species name (a form change) is logged, not sent. Checked offline on the real Scatterbug → Spewpa states (`fixtures/private/r2-*`), and live: Skitty → Delcatty with a Moon Stone sent one `evolve` with `nick: "Delcatty"`. A level-up evolution right after a battle is skipped on purpose: runs level with the Endless Candy, so it rarely happens (the same scan would catch it once the battle ends)
  - [x] Web app: `evolve` sets the nickname when `nick` is sent, and its undo puts it back (dev sheet)
- [ ] **Trades**: tracked id replaced by an unknown id with a different OT in the same slot. In Run & Bun gift mons come from NPC trades, so they always land in the party (no gift-to-PC case). To check on a real trade: the met location (vanilla uses 254, "in-game trade", which the map table doesn't cover) and the slot transition on the trade screen
- [ ] **`sync`**: snapshot of mons, defeated trainers, splits and play time on script start and on any play-time discontinuity (today a jump only resets the battle tracker silently)
- Not needed: new-run detection. Starting a new run is manual (Reset Run on the sheet); the Lua side just sends events with the current trainer id as `run`
- [~] Output to the relay (`relay_client.lua`): TCP to `127.0.0.1:38765`, reconnect every 2 s, events dropped while disconnected; never writes after the relay closes (SIGPIPE would kill mGBA); ids `<run>:<session>.<n>` stamped in `tracker.lua`. Written against mGBA 0.10.3's socket source; tested on a fake of its API and with `tracker.lua` on fake memory; not yet live in mGBA
- [ ] Cheaper battle reads (fetch HP first, the rest only on change). Optional; do it with the party scans
- [ ] Doubles: use `gBattlerAttacker` once found, then drop `ambiguous`
- [ ] `indirect` flag on kills (needs the attacker)

## 3. Relay (`relay/relay.mjs`)

- [x] TCP server on `127.0.0.1:38765` for the tracker's newline-delimited JSON; never writes back
- [x] Ids are stamped by the tracker, not the relay (nothing to persist)
- [x] In-memory queue taken every 200 ms and sent as one independent request; a failed request retried 3 times (after 1, 2, 4 s, ±50% jitter), then its events dropped. Best effort by choice: nothing to clean up, no stale events after a Reset Run, no request held up behind a failing one (a retried event can land after a later one; the sheet logs a kill that beats its catch)
- [x] HTTPS POST to the web app with the shared token (Node, no packages), follows the Apps Script redirect
- [x] Config from `.env` (`WEB_APP_URL`, `TOKEN`; `--env` for another file, `--port`), start-up check of URL and token
- [x] Tests (`npm run test:relay`): fake web app, offline, refused token, broken script, retries and dropping, TCP framing and disconnects (mutation-checked)
- [x] End to end by hand against the dev sheet over TCP: catch, kill and a repeated catch → row added, KC 1, duplicate skipped

## 4. Apps Script / sheet (`appsscript/`)

Done and tested on the **dev copy** only.

- [x] `Sorter.js` refactored into `Rankings.js` helpers; manual buttons and web app share the same row logic
- [x] Sort range widened to `D3:Y102` with the hidden id column `Y`; `U:W` formulas verified to survive sorting
- [x] Web app `doPost` / `doGet`, token check, lock, `@OnlyCurrentDoc`
- [x] Events: `catch`, `kill`, `death`, `evolve`, `trade`, `split`, `sync`
- [x] Idempotency by event id, run mismatch held, journal in hidden `_Events`, issues in `_Issues`
- [x] `sync` reconcile: rewind, forward jump, killer re-attribution, adds missing mons
- [x] Dev-only `dump` / `reset` / `undo` actions (refuse unless `ENV=dev`)
- [ ] Event for a mon that vanishes from party and boxes (`missing`); the design has it, the web app doesn't
- [x] Undo latest tracking change button (`AA11`): reverts the newest event that changed the sheet and deletes it from `_Events` (dev sheet, via the dev-only `undo` action)
- [ ] "Resync" sheet menu item (from the design)
- [ ] Use the `ambiguous` flag on kills (today ignored; could write an `_Issues` row)
- [ ] Known limit: one enemy mon's credit across two jumped-between timelines goes to the most recent killer

## 5. Testing and tooling

- [x] `npm run test:sheet`: 18 scenarios against the dev web app (~2 min)
- [x] `npm run test:lua`: 50 scenarios on a fake memory, no emulator (mutation-checked, including the catch and evolution rules)
- [x] `setup-clasp`, `gen-token`, `deploy`, `deploy:dev`
- [x] Read-only probes `lua/spike/probe.lua`, `probe2.lua`
- [x] Remote control `lua/dev/remote.lua` + `tools/remote.py`: buttons, screenshots, savestates and watchers from a script (live)
- [x] Tests for catches and evolutions
- [ ] Tests for trades and `sync` as they are written
- [ ] Emulator-in-the-loop test: mGBA with the ROM and a fixture state, assert on the emitted events. 0.10.3 has no `--script` flag, but the remote can load states and drive the game once loaded
- [x] `npm run test:relay`: 12 relay tests (`node:test`), no network
- [~] End-to-end: Lua output → relay → dev web app → sheet, run once by hand (not automated; the Lua part on fake memory and a fake socket)
- [ ] `tools/replay.py` to post recorded event streams (from the design; may not be needed)

## 6. Rollout to the real sheet

- [ ] Deploy the web app to the real sheet (`clasp` prod file, Script Properties `TOKEN`, no `ENV=dev`) and approve its permissions once
- [ ] Run with the relay against the real sheet for a few battles; compare with manual counts
- [x] Decided how to start a new run: press Reset Run (clears `Rankings`, `_Events`, `_Issues` and the tracked run); the first event after it sets the new run
- [ ] Play a full split live and fix attribution problems

## 7. Docs

- [x] README, MEMORY_MAP, lua_progress, this file
- [x] DESIGN.md refreshed to match what is built: a badge increase advances the split (read as the number of defeated gym leaders; the web app sets `Badges`), field-mon kill credit with `ambiguous` in doubles, catch and evolution detection, what is not built yet
- [x] README section for the relay
- [ ] README section for the captures once they exist

## Suggested order

1. **Catches** done and live
2. **Evolutions** done; **trades** next (same party scan)
3. **`sync`**
4. **Relay** done, plus the Lua socket client; next, a live session with the tracker and relay against the dev sheet
5. Roll out to the real sheet; first real leader win confirms the `split` flow
6. Doubles attacker and polish
