# Run & Bun kill tracker

Tooling to keep a Google Sheets kill tracker (the `Rankings` tab of the "R&B kill sheet") up to date automatically while playing Pokémon Run & Bun in a hardcore Nuzlocke.

The long-term goal is for mGBA to feed the sheet directly; see [DESIGN.md](DESIGN.md) for the full design and [PROGRESS.md](PROGRESS.md) for what is done and what is left. **What exists today:** a refactored Apps Script project with a web app endpoint that accepts game events, and an mGBA Lua script that tracks battles (kills, deaths, splits), catches and evolutions. The Lua script prints events to the mGBA console; the relay that forwards them to the sheet is not built yet.

## What's here

```
appsscript/
  Sorter.js      onEdit handlers (manual buttons, row setup, sorting)
  Rankings.js    shared helpers for the Rankings tab (used by onEdit and the web app)
  WebApp.js      web app: receives events and applies them to the sheet
  appsscript.json
lua/
  tracker.lua    mGBA entry point: load this in mGBA
  battle.lua     battle tracker (kill / death / split events)
  mons.lua       mon tracker (catch events, including the starter)
  gen3.lua       Gen 3 decoding (party structs, names, flags, play time)
  addresses.lua  the Run & Bun 1.0.7 memory map
  json.lua       JSON encoder
  spike/         read-only probes used to find the addresses
  dev/remote.lua remote control for experiments (see tools/README.md)
docs/
  MEMORY_MAP.md  the Run & Bun 1.0.7 addresses and struct layouts
  lua_progress/  Lua tracker status (README.md) and how the addresses were found (spike-log.md)
scripts/
  gen-token.js   generates the shared secret
  setup-clasp.js asks for the prod and dev script IDs and writes the two clasp files
  deploy-dev.sh  pushes to the DEV sheet and (re)deploys the web app
tools/
  remote.py      sends Lua chunks to lua/dev/remote.lua running in mGBA (see tools/README.md)
  state.py       reads RAM out of a savestate offline
.claude/
  skills/remote-controlling-mgba/   how a Claude Code session drives the game with the remote
  agents/mgba-driver.md             subagent for long play-and-trace sequences
tests/sheet/
  run.mjs        scenario tests against the dev web app
tests/lua/
  run.lua        tracker tests (no emulator needed)
  fakemem.lua    fake memory the tests write game structures into
fixtures/private/   your ROM / savestates (gitignored)
```

## The sheet

`Rankings` rows 3–102 hold up to 100 Pokémon.

| Column | Meaning |
|--------|---------|
| `E` | formula (Gemstones lookup on Total KC), never written by scripts |
| `F` | Status (`Alive` / `Dead`) |
| `H` / `I` / `J` | Nickname / Species / Encounter Location |
| `K:S` | KC for Split 1–8 and E4 Split |
| `T` | Total KC |
| `W` | Add KO checkbox |
| `Y` | hidden mon ID (`personality:otid`), written only by the web app |

Right-hand panel (column `AA`): `AA2` Attempt, `AA4` Badges, `AA7` Advance Split, `AA9` Reset Run, `AA11` Undo latest tracking change. **Badges is the current split**: a kill goes in column `K + Badges`.

The table is sorted by Total KC (descending), then Status (Alive above Dead), over `D3:Y102`.

### Apps Script refactor

`Sorter.js` used to hold everything in one `onEdit`. The row logic now lives in `Rankings.js` (`initRow`, `blankRow`, `recomputeTotal`, `addKc`, `sortRankings`, …) so the manual buttons and the web app behave identically. Behavior changes from the original: the sort range widens from `D3:T102` to `D3:Y102` to carry the ID column, and Reset Run also clears that column and the web app's event log.

Script writes don't trigger `onEdit`, which is why the web app calls the shared helpers itself.

## Web app

`WebApp.js` is deployed as a web app (runs as the deploying user, anonymous access) and is protected by a shared secret. It declares `@OnlyCurrentDoc`, so it only asks for access to the spreadsheet it is attached to.

Every request is JSON containing `token`. `POST` bodies are sent as `text/plain` to avoid a CORS preflight.

### Events

```json
{"token": "...", "events": [ ... ]}
```

Every event has `id` (unique; repeats are ignored), `run` (identifies the save/run), `playTime` (in-game play time in seconds) and `type`:

| type | fields | effect |
|------|--------|--------|
| `catch` | `pid`, `species`, `nick`, `location` | add a row (status Alive, KC 0) in the first empty row |
| `kill` | `pid`, `split` (1–9), `trainer`, `key` | +1 in that split's column |
| `death` | `pid` | Status → `Dead` |
| `evolve` | `pid`, `from`, `to`, `nick` (optional) | change species in place (and the nickname, if sent), KC kept |
| `trade` | `old_pid`, `pid`, `species`, `nick`, `location` | replace the row's mon in place, KC kept |
| `split` | `badges` (0–8) | set Badges directly |
| `sync` | `mons[]`, `defeated[]`, `badges`, `complete` | reconcile after a savestate / save load |

`pid` is the personality value plus original-trainer ID (`"0xA1B2C3D4:0x1234ABCD"`), which stays the same through evolution and nickname changes. Rows move on every sort, so the sheet always finds a Pokémon by this ID.

Responses: `{ok: true, results: [{id, status}]}` where status is `applied`, `duplicate`, `ignored` or `held` (event from a different run; press Reset Run to switch).

### Event log and `sync`

Every applied event is recorded in a hidden `_Events` tab together with how to undo it. Problems (unknown mon, full table, skipped undo) go to a hidden `_Issues` tab.

**Undo latest tracking change** (`AA11`) reverts the newest event in `_Events` that changed the sheet and deletes it from the log, so a later `sync` can't bring it back. Each press undoes one more; a toast says what was undone. Events already undone by a rewind are skipped. If you edited the affected cells by hand since, your edit is kept and the skip is logged to `_Issues`. If the mon's row is gone (cleared by hand), nothing changes but the event is still removed from the log, and the toast says so. A deleted event's id is forgotten, so if the same event were sent again it would be applied again.

`sync` handles loading savestates and older saves, where the game goes back in time but the sheet doesn't. It carries a snapshot of the game: the mons you have, which trainers are defeated, and the badge count. The sheet then:

- undoes events with `playTime` later than the snapshot's,
- keeps events that still match the game (e.g. a kill whose trainer is still defeated) and re-applies ones that match again,
- copies species and nickname for known mons from the snapshot, adds mons that are in the game but not on the sheet, and sets Badges.

Limitation: kill credit for one enemy Pokémon can belong to only one of your mons. If you play the same fight twice with different killers and then jump between the two timelines, the most recent credit wins. Manual Add KO clicks are never undone.

## Development setup

Requires Node (see `.nvmrc`) and `clasp` (installed by `npm install`).

1. `npm install`, then `npx clasp login`.
2. **Work on a copy of the sheet.** Make a copy of the spreadsheet (File → Make a copy); it comes with its own bound script. Then run `npm run setup-clasp`. It asks for the prod script ID and the dev (copy) script ID (Apps Script → Project Settings → IDs) and writes `.clasp.json` (prod, `rootDir` set to `appsscript`) and `.clasp.dev.json` (dev). Both files are gitignored because they contain script IDs. Re-running offers your current IDs as defaults. Plain `clasp` commands use the prod file; `deploy-dev.sh` is the only thing that uses the dev file, and it never touches prod.
3. `npm run gen-token` creates a random `TOKEN` in `.env` and prints it. In the dev copy's Apps Script → Project Settings → Script Properties set:
   - `TOKEN` — the printed value
   - `ENV` — `dev` (enables the test-only `dump` and `reset` actions; they refuse to run otherwise, so tests can't touch a real sheet)
4. `npm run deploy:dev` stages the files, pushes them to the dev script, deploys, and writes `DEPLOYMENT_ID` and `WEB_APP_URL` to `.env`. Re-running redeploys to the same URL.
5. Open `WEB_APP_URL` once in a browser and approve the permission prompt. You should then see `{"ok":false,"error":"unauthorized"}`, which means it's working and just needs the token.

`.env`, `.clasp.json`, `.clasp.dev.json` and `fixtures/private/` are gitignored.

## Tests

```
npm run test:sheet                    # all scenarios
npm run test:sheet -- --only rewind   # scenarios whose name contains "rewind"
npm run test:sheet -- --dump          # also print sheet state after each scenario
```

These run against the **dev** web app and take around two minutes (each request takes a few seconds). Each scenario resets the dev sheet first and again at the end. They cover catches, kills and sorting, deaths, evolutions, trades, splits, rewinds and forward jumps via `sync`, killer re-attribution, run mismatches, duplicate events, and that row formulas (including the `U:W` bar graph) still reference their own row after a sort.

## Lua tracker

Load `lua/tracker.lua` in mGBA 0.10.3 (Tools → Scripting → File → Load script) with Run & Bun 1.0.7 running. It checks the ROM's name tables first and refuses to start on anything else. Events appear in the scripting console as `EVENT {json}`:

| type | when |
|------|------|
| `kill` | an enemy mon in a **trainer** battle faints; credited to your mon on the field. `split` is leaders defeated + 1, `trainer` is the opponent's id, `key` is `<trainer>:<enemy party slot>` |
| `death` | one of your mons fainted in a battle (sent when the battle ends) |
| `split` | a gym leader was beaten; `badges` is how many of the eight leaders are defeated |
| `catch` | a mon joined you: a battle ended with the mon caught (it is read from the party or box it was stored in, so the nickname is final), or a new mon with your OT id appeared in the party outside battle (the starter). `species`, `nick`, `location` (met location name) |
| `evolve` | a known party mon's species changed, read the same with a valid checksum on two party scans (about a second apart). `from`, `to` are species names; `nick` is sent only when the game renamed the mon, which it does when the mon still had its species name (Scatterbug → Spewpa). A change that keeps the species name (a form change) is only logged |

Events carry `run` (your trainer id) and `playTime`; `id` is added later by the relay. Kills in doubles use the leftmost live mon and set `ambiguous` when both of yours were alive (the attacker isn't read yet). A jump in play time (loading a savestate or a save) drops the current battle without emitting anything.

Mons already in the party and boxes when the script starts, or after loading a savestate or save, are treated as known and not sent: the sheet may already have them (hand-entered rows have no id), and `sync` will reconcile them. A mon is sent at most once per timeline, and the sheet ignores a catch for an id it already has. Catching a species you already have is sent as a new mon (and logged); evolution lines are not checked.

Not detected yet: trades (a new party mon with another OT id is only logged), and the `sync` snapshot.

## Lua tests

```
npm run test:lua      # needs a `lua` interpreter (5.4+) on the PATH
```

They run the tracker against a fake memory, no emulator or ROM. The scenarios named "observed" replay frame sequences logged from real fights, such as the enemy slot briefly showing a replacement's species with the previous mon's HP during a switch-in.

## Testing in the emulator (remote control)

`lua/dev/remote.lua` and `tools/remote.py` let a script drive a running mGBA: press buttons, take screenshots, save and load states, and log memory every frame. Load `remote.lua` in mGBA once, then send it Lua chunks:

```sh
python3 tools/remote.py 'press("A"); wait(30); shot("now")'   # screenshot in .remote/now.png
```

This is how catches, evolutions and PC moves were observed (the traces are in [docs/lua_progress/spike-log.md](docs/lua_progress/spike-log.md)). It is also the basis for checking the tracker against the real game rather than fake memory. Setup, the commands a chunk can use, and how it works are in [tools/README.md](tools/README.md). `tools/state.py` reads the same memory out of saved states without the emulator. In Claude Code, the `remote-controlling-mgba` skill and the `mgba-driver` subagent use these tools.

## Not built yet

See [DESIGN.md](DESIGN.md): detection of trades; the `sync` snapshot; and the local relay that forwards the Lua script's events to the web app.
