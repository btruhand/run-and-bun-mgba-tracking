# Progress

Last updated 2026-10-10. The design is in [DESIGN.md](DESIGN.md); the Lua details are in [docs/lua_progress/](docs/lua_progress/README.md).

Legend: `[x]` done and checked, `[~]` done but only partly checked (noted), `[ ]` not started.
"Live" means confirmed in mGBA during play. "Dev sheet" means confirmed on the copy of the spreadsheet, not the real one.

```
mGBA (Lua tracker) ──NDJSON/TCP──▶ relay (not built) ──HTTPS──▶ Apps Script web app ──▶ Rankings sheet
   battle done                                                    done on dev copy
```

## Summary

| Area | State |
|------|-------|
| Game data (RAM / ROM map) | Party, battle, flags, names found. PC boxes and doubles attacker still open |
| Lua tracker | Battles done and live (kills, deaths, splits). Captures, evolutions, trades, `sync`, output to the relay not started |
| Relay | Not started |
| Apps Script / sheet | Web app, journal and reconcile done and tested on the dev sheet. Not on the real sheet |
| Testing | Sheet tests (13) and Lua tests (23) pass. No emulator-in-the-loop or end-to-end test |
| Rollout to the real sheet | Not started |

## 1. Game data (RAM / ROM)

Details: [docs/MEMORY_MAP.md](docs/MEMORY_MAP.md), method in [docs/lua_progress/spike-log.md](docs/lua_progress/spike-log.md).

- [x] Party, party count, enemy party, mon struct decode (live)
- [x] Save block pointers, play time, trainer id (live)
- [x] `gMain.inBattle`, `gBattleTypeFlags`, `gBattleMons` and its fields, opponent trainer id (live)
- [x] Trainer-defeated flags (live), RAM id ↔ `gTrainers` entry offset (four trainers)
- [x] ROM tables: species names, `gTrainers`, map section names (map names checked on savestates only)
- [ ] PC boxes: `gPokemonStorage` (the community exporter's `0x02028848` is unchecked). Needs a state with mons in boxes
- [ ] `gBattlerAttacker`, to credit doubles kills exactly
- [ ] Gym leader ids confirmed against a real leader fight (derived from the table so far)
- Skipped on purpose: badge flags (the split comes from leader flags), `gBattleOutcome`, `gBattlerPartyIndexes`

## 2. Lua tracker (`lua/`)

- [x] Entry point `tracker.lua`: ROM check, play-time-jump reset, `EVENT {json}` console output
- [x] `gen3.lua`, `addresses.lua`, `json.lua`
- [x] Battle tracker `battle.lua`
  - [x] `kill`: trainer battles only, credited to the mon on the field, identity check against switch-in glitches, one credit per enemy slot (live)
  - [x] `death`: any battle, sent when it ends, once per mon (live, wild)
  - [x] `split`: gym leader flags set after a battle (tests only; no leader win seen live yet)
  - [~] Doubles: leftmost live mon credited, `ambiguous` flagged (tests only)
  - [ ] Blackout (whole party wiped) in a wild fight, not seen live
- [ ] **Captures**: scan party and PC boxes for new ids, debounce (2+ scans, skip transitions), species / nickname / met location, gifts and starter included
- [ ] **Evolutions**: same id, different species between scans
- [ ] **Trades**: tracked id replaced by an unknown id with a different OT in the same slot
- [ ] **`sync`**: snapshot of mons, defeated trainers, splits and play time on script start and on any play-time discontinuity (today a jump only resets the battle tracker silently)
- [ ] New-run detection (a different trainer id) and what the script does about it
- [ ] Output to the relay: socket client with reconnect (mGBA 0.10.3's `socket` API is not yet verified)
- [ ] Cheaper battle reads (fetch HP first, the rest only on change). Optional; do it with the party scans
- [ ] Doubles: use `gBattlerAttacker` once found, then drop `ambiguous`
- [ ] `indirect` flag on kills (needs the attacker)

## 3. Relay (`relay/`, not created)

- [ ] Localhost TCP listener for the Lua script's newline-delimited JSON
- [ ] Stamp event ids (`<run>:<seq>`), sequence persisted across restarts
- [ ] Disk-backed queue, retries, batching
- [ ] HTTPS POST to the web app with the shared token (stdlib Python)
- [ ] Config from `.env` (web app URL, token), start/stop instructions
- [ ] Tests (fake web app endpoint, restart and offline cases)

## 4. Apps Script / sheet (`appsscript/`)

Done and tested on the **dev copy** only.

- [x] `Sorter.js` refactored into `Rankings.js` helpers; manual buttons and web app share the same row logic
- [x] Sort range widened to `D3:Y102` with the hidden id column `Y`; `U:W` formulas verified to survive sorting
- [x] Web app `doPost` / `doGet`, token check, lock, `@OnlyCurrentDoc`
- [x] Events: `catch`, `kill`, `death`, `evolve`, `trade`, `split`, `sync`
- [x] Idempotency by event id, run mismatch held, journal in hidden `_Events`, issues in `_Issues`
- [x] `sync` reconcile: rewind, forward jump, killer re-attribution, adds missing mons
- [x] Dev-only `dump` / `reset` actions (refuse unless `ENV=dev`)
- [ ] Event for a mon that vanishes from party and boxes (`missing`); the design has it, the web app doesn't
- [ ] "Resync" sheet menu item and "undo last event" command (from the design)
- [ ] Use the `ambiguous` flag on kills (today ignored; could write an `_Issues` row)
- [ ] Known limit: one enemy mon's credit across two jumped-between timelines goes to the most recent killer

## 5. Testing and tooling

- [x] `npm run test:sheet`: 13 scenarios against the dev web app (~2 min)
- [x] `npm run test:lua`: 23 scenarios on a fake memory, no emulator (mutation-checked)
- [x] `setup-clasp`, `gen-token`, `deploy:dev`
- [x] Read-only probes `lua/spike/probe.lua`, `probe2.lua`
- [ ] Tests for captures, evolutions, trades and `sync` as they are written
- [ ] Emulator-in-the-loop test: mGBA with the ROM and a fixture state, assert on the emitted events (needs the 0.10.3 CLI flags)
- [ ] End-to-end test: Lua output → relay → dev web app → sheet
- [ ] `tools/replay.py` to post recorded event streams (from the design; may not be needed)

## 6. Rollout to the real sheet

- [ ] Deploy the web app to the real sheet (`clasp` prod file, Script Properties `TOKEN`, no `ENV=dev`) and approve its permissions once
- [ ] Run with the relay against the real sheet for a few battles; compare with manual counts
- [ ] Decide how to start a new run (Reset Run, then the first `sync`)
- [ ] Play a full split live and fix attribution problems

## 7. Docs

- [x] README, MEMORY_MAP, lua_progress, this file
- [ ] Refresh DESIGN.md: it still says the split comes from badge flags (it uses leader flags), assumes `gBattlerAttacker` attribution, and its spike and build-plan sections predate the findings
- [ ] README sections for the relay and the captures once they exist

## Suggested order

1. PC box address (needs a state with boxed mons), then **captures**
2. **Evolutions** and **trades** (same party and box scan)
3. **`sync`** and new-run handling
4. **Relay**, plus the Lua socket output; first end-to-end run against the dev sheet
5. Roll out to the real sheet; first real leader win confirms the `split` flow
6. Doubles attacker, polish and the design refresh
