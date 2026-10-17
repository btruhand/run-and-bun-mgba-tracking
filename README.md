# Run & Bun kill tracker

Tooling to keep a Google Sheets kill tracker (the `Rankings` tab of the "R&B kill sheet") up to date automatically while playing Pokémon Run & Bun in a hardcore Nuzlocke.

The long-term goal is for mGBA to feed the sheet directly; see [DESIGN.md](docs/DESIGN.md) for the full design and [PROGRESS.md](docs/PROGRESS.md) for what is done and what is left. **What exists today:** a refactored Apps Script project with a web app endpoint that accepts game events, and an mGBA Lua script that tracks battles (kills, deaths, splits), catches and evolutions. The Lua script sends events over a local socket to a small relay, which forwards them to the sheet.

## How to use

You need mGBA 0.10.3 (higher versions probably work but was not tested), the Run & Bun 1.0.7 ROM, Node 22 or newer and a clone of this repo.

### One-time setup

1. **Copy the sheet.** Open the [R&B kill sheet template](https://docs.google.com/spreadsheets/d/1I1SvHrP7H5h6KThq09LtJBzA1QQyLwFuUkNxWpvRkyE/edit?usp=sharing) and choose File → Make a copy. The copy comes with its own Apps Script project that already has the scripts in it, so there is nothing to upload.
2. **Generate the token.** In the repo, run:

   ```sh
   npm run gen-token
   ```

   It writes a random `TOKEN` to `.env` and prints it. The relay sends this token with every request, and the web app refuses requests without it.

3. **Give the script the token.** In your copy of the sheet, open Extensions → Apps Script, then Project Settings (the gear icon) → Script Properties → Add script property. Set the property name to `TOKEN` and the value to the printed token, then click Save script properties.
4. **Deploy the web app.** Still in Apps Script, click Deploy → New deployment, click the gear next to "Select type" and choose Web app. Set:
   - Execute as: **Me** (the web app writes to the sheet as you)
   - Who has access: **Anyone** (the relay has no Google login; the token is what protects it)

   Click Deploy. Google then asks you to authorize the script:
   1. Click Authorize access and choose your Google account.
   2. You'll see "Google hasn't verified this app", because it's your own copy of the script and not a published app. Click Advanced → Go to _(project name)_ (unsafe).
   3. Allow access. The script asks only for the spreadsheet it is attached to (it declares `@OnlyCurrentDoc`).

   Copy the Web app URL (it ends in `/exec`) and add it to `.env`:

   ```
   WEB_APP_URL=https://script.google.com/macros/s/.../exec
   ```

   Open that URL in a browser. `{"ok":false,"error":"unauthorized"}` means the web app is running and only needs the token.

### Each time you play

1. Start the relay in a terminal and leave it running:

   ```sh
   npm run relay
   ```

   It checks the URL and token when it starts.

2. With the ROM running in mGBA, load `lua/tracker.lua` (Tools → Scripting → File → Load script). The scripting console shows `relay: connected on port 38765`, and catches, kills, deaths, evolutions and badges now show up on the `Rankings` tab.

The sheet tracks one run (save file) at a time; it locks onto the first one that sends it an event. To start a new run, press Reset Run (`AA9`). See [Relay](#relay) and [Lua tracker](#lua-tracker) for details.

## Redeploying

If you'd like to update the Apps Script (for example, because there was an update), you can redeploy in the following two ways:

### With `npm run deploy`

You will need the `clasp` setup from [Development setup](#development-setup)):

```sh
npm run deploy
```

It pushes the files to your script and updates the deployment whose ID is `DEPLOYMENT_ID` in `.env` to a new version, so the WebApp URL stays the same. If you created the deployment by hand in the one-time setup, `.env` has no `DEPLOYMENT_ID` yet, and the script would create a new deployment instead. Add it first: it is the part of your web app URL between `/s/` and `/exec`.

```
DEPLOYMENT_ID=AKfycb...
```

### Through the Apps Script editor

1. Replace the project's files with the ones in `appsscript/` (paste them in, or run `npx clasp push`).
2. Click Deploy → Manage deployments.
3. Click the pencil (Edit) icon on your web app deployment.
4. Under Version, choose **New version**, then click Deploy.

Don't use Deploy → New deployment for this, and don't pick an older version number in step 4: the web app keeps serving whichever version the deployment points to.

> [!NOTE]
> Whichever option you choose, **always redeploy as a new version of the existing deployment; do not create a new deployment.** A new deployment gets a new web app URL, and you would have to update `WEB_APP_URL` in `.env` and approve the permission prompt again.

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
  relay_client.lua  sends events to the relay over localhost TCP
  spike/         read-only probes used to find the addresses
  dev/remote.lua remote control for experiments (see tools/README.md)
docs/
  MEMORY_MAP.md  the Run & Bun 1.0.7 addresses and struct layouts
  lua_progress/  Lua tracker status (README.md) and how the addresses were found (spike-log.md)
scripts/
  gen-token.js   generates the shared secret
  setup-clasp.js asks for the prod and dev script IDs and writes the two clasp files
  deploy.sh      pushes to a sheet's script, (re)deploys the web app and writes its URL to an env file
  deploy-dev.sh  deploy.sh for the DEV sheet (.clasp.dev.json, .env.dev)
relay/
  relay.mjs      forwards the tracker's events to the web app
tools/
  remote.py      sends Lua chunks to lua/dev/remote.lua running in mGBA (see tools/README.md)
  state.py       reads RAM out of a savestate offline
.claude/
  skills/remote-controlling-mgba/   how a Claude Code session drives the game with the remote
  skills/testing-on-dev-sheet/      simulating events against the dev sheet (sim.mjs runs a list of steps)
  agents/mgba-driver.md             subagent for long play-and-trace sequences
tests/sheet/
  run.mjs        scenario tests against the dev web app
tests/lua/
  run.lua        tracker tests (no emulator needed)
  fakemem.lua    fake memory the tests write game structures into
tests/relay/
  relay.test.mjs relay tests (no network needed)
fixtures/private/   your ROM / savestates (gitignored)
```

## The sheet

`Rankings` rows 3–102 hold up to 100 Pokémon.

| Column          | Meaning                                                          |
| --------------- | ---------------------------------------------------------------- |
| `E`             | formula (Gemstones lookup on Total KC), never written by scripts |
| `F`             | Status (`Alive` / `Dead`)                                        |
| `H` / `I` / `J` | Nickname / Species / Encounter Location                          |
| `K:S`           | KC for Split 1–8 and E4 Split                                    |
| `T`             | Total KC                                                         |
| `W`             | Add KO checkbox                                                  |
| `Y`             | hidden mon ID (`personality:otid`), written only by the web app  |

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

| type     | fields                                          | effect                                                       |
| -------- | ----------------------------------------------- | ------------------------------------------------------------ |
| `catch`  | `pid`, `species`, `nick`, `location`            | add a row (status Alive, KC 0) in the first empty row        |
| `kill`   | `pid`, `split` (1–9), `trainer`, `key`          | +1 in that split's column                                    |
| `death`  | `pid`                                           | Status → `Dead`                                              |
| `evolve` | `pid`, `from`, `to`, `nick` (optional)          | change species in place (and the nickname, if sent), KC kept |
| `trade`  | `old_pid`, `pid`, `species`, `nick`, `location` | replace the row's mon in place, KC kept                      |
| `split`  | `badges` (0–8)                                  | set Badges directly                                          |
| `sync`   | `mons[]`, `defeated[]`, `badges`, `complete`    | reconcile after a savestate / save load                      |

`pid` is the personality value plus original-trainer ID (`"0xA1B2C3D4:0x1234ABCD"`), which stays the same through evolution and nickname changes. Rows move on every sort, so the sheet always finds a Pokémon by this ID.

Responses: `{ok: true, results: [{id, status}]}` where status is `applied`, `duplicate`, `ignored` (unknown mon, full table), `failed` (the script threw while applying it, e.g. the sheet rejected a value), `held` (event from a different run; press Reset Run to switch) or `rejected` (no type, run or id). An error outside any one event (the lock, opening the sheet) answers `{ok: false, error: <message>}`.

### Event log and `sync`

Every event the web app receives is recorded in a hidden `_Events` tab, with its `status` (as in the response; a sync is `reconciled`) and, for applied ones, how to undo it. A resent event that was applied is answered `duplicate`; one that wasn't (`failed`, `ignored`, `held`) is handled again, for example when the relay retries a request whose answer was lost, and its row is updated, keeping the links to the earlier issues. Problems go to a hidden `_Issues` tab: unknown mon, full table, skipped undo, and any error the script hits, with its message. An event's `issue reference` column lists the `_Issues` rows about it, each a link to its row. Only `applied` events are rewound, re-applied or undone.

**Undo latest tracking change** (`AA11`) reverts the newest event in `_Events` that changed the sheet and deletes it from the log, so a later `sync` can't bring it back. Each press undoes one more; a toast says what was undone. Events already undone by a rewind are skipped. If you edited the affected cells by hand since, your edit is kept and the skip is logged to `_Issues`. If the mon's row is gone (cleared by hand), nothing changes but the event is still removed from the log, and the toast says so. A deleted event's id is forgotten, so if the same event were sent again it would be applied again.

`sync` handles loading savestates and older saves, where the game goes back in time but the sheet doesn't. It carries a snapshot of the game: the mons you have, which trainers are defeated, and the badge count. The sheet then:

- undoes events with `playTime` later than the snapshot's,
- keeps events that still match the game (e.g. a kill whose trainer is still defeated) and re-applies ones that match again,
- copies species and nickname for known mons from the snapshot, adds mons that are in the game but not on the sheet, and sets Badges.

Limitation: kill credit for one enemy Pokémon can belong to only one of your mons. If you play the same fight twice with different killers and then jump between the two timelines, the most recent credit wins. Manual Add KO clicks are never undone.

## Development setup

Requires Node 22 or newer (`engines` in `package.json`; `npm install` refuses older versions because `.npmrc` sets `engine-strict`) and `clasp` (installed by `npm install`). `.nvmrc` pins the exact version, and `.envrc` selects it if you use direnv.

1. `npm install`, then `npx clasp login`.
2. **Work on a copy of the sheet.** Make a copy of the spreadsheet (File → Make a copy); it comes with its own bound script. Then run `npm run setup-clasp`. It asks for the prod script ID and the dev (copy) script ID (Apps Script → Project Settings → IDs) and writes `.clasp.json` (prod, `rootDir` set to `appsscript`) and `.clasp.dev.json` (dev). Both files are gitignored because they contain script IDs. Re-running offers your current IDs as defaults. Plain `clasp` commands and `npm run deploy` use the prod file; `npm run deploy:dev` uses the dev file and never touches prod.
3. `npm run gen-token -- --env .env.dev` creates a random `TOKEN` in `.env.dev` and prints it (without `--env` it writes `.env`). In the dev copy's Apps Script → Project Settings → Script Properties set:
   - `TOKEN` — the printed value
   - `ENV` — `dev` (enables the test-only `dump` and `reset` actions; they refuse to run otherwise, so tests can't touch a real sheet)
4. `npm run deploy:dev` stages the files, pushes them to the dev script, deploys, and writes `DEPLOYMENT_ID` and `WEB_APP_URL` to `.env.dev`. Re-running redeploys to the same URL.
5. Open `WEB_APP_URL` once in a browser and approve the permission prompt. You should then see `{"ok":false,"error":"unauthorized"}`, which means it's working and just needs the token.

`npm run deploy` does the same for the prod script in `.clasp.json`, reading and writing `.env`; it is `scripts/deploy.sh`, and `deploy:dev` is `scripts/deploy.sh --clasp .clasp.dev.json --env .env.dev`. Pass `--clasp` and `--env` to deploy any other copy (`npm run deploy -- --help`). Either way, a new deployment needs the browser approval in step 5 once. The clasp commands need "Google Apps Script API" turned on in your [Apps Script settings](https://script.google.com/home/usersettings).

`.env`, `.env.*`, `.clasp.json`, `.clasp.dev.json` and `fixtures/private/` are gitignored.

### Commit hook

`npm install` points git at `.githooks/` (the `prepare` script runs `git config core.hooksPath .githooks`). Its `commit-msg` hook refuses a `feat`, `fix`, `refactor`, `test` or `perf` commit that doesn't stage `docs/PROGRESS.md`, so the progress doc is updated (ticked off, or marked as not going ahead) in the same commit. If there is nothing to record, add a `Progress: none` line to the commit message. Other types (`docs`, `build`, `chore`, ...), merges and reverts are not checked.

## Tests

```
npm run test:sheet                    # all scenarios
npm run test:sheet -- --only rewind   # scenarios whose name contains "rewind"
npm run test:sheet -- --dump          # also print sheet state after each scenario
```

These run against the **dev** web app (`WEB_APP_URL` and `TOKEN` from `.env.dev`) and take around two minutes (each request takes a few seconds). Each scenario resets the dev sheet first and again at the end. They cover catches, kills and sorting, deaths, evolutions, trades, splits, rewinds and forward jumps via `sync`, killer re-attribution, run mismatches, duplicate events, errors in an event or a sync step going to `_Issues` without stopping the rest, every event's `_Events` row with its status and issue reference, and that row formulas (including the `U:W` bar graph) still reference their own row after a sort.

To try a sequence of events by hand, `node .claude/skills/testing-on-dev-sheet/sim.mjs steps.json` resets the dev sheet, plays the steps and prints `Rankings`, `_Events` and `_Issues` (see `.claude/skills/testing-on-dev-sheet/SKILL.md`).

## Lua tracker

Load `lua/tracker.lua` in mGBA 0.10.3 (Tools → Scripting → File → Load script) with Run & Bun 1.0.7 running. It checks the ROM's name tables first and refuses to start on anything else. Each event appears in the scripting console as `EVENT {json}` and is sent to the [relay](#relay) if it is running (otherwise the line ends with `(not sent: relay not connected)`):

| type     | when                                                                                                                                                                                                                                                                                                                                                    |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kill`   | an enemy mon in a **trainer** battle faints; credited to your mon on the field. `split` is leaders defeated + 1, `trainer` is the opponent's id, `key` is `<trainer>:<enemy party slot>`                                                                                                                                                                |
| `death`  | one of your mons fainted in a battle (sent when the battle ends)                                                                                                                                                                                                                                                                                        |
| `split`  | a gym leader was beaten; `badges` is how many of the eight leaders are defeated                                                                                                                                                                                                                                                                         |
| `catch`  | a mon joined you: a battle ended with the mon caught (it is read from the party or box it was stored in, so the nickname is final), or a new mon with your OT id appeared in the party outside battle (the starter). `species`, `nick`, `location` (met location name)                                                                                  |
| `evolve` | a known party mon's species changed, read the same with a valid checksum on two party scans (about a second apart). `from`, `to` are species names; `nick` is sent only when the game renamed the mon, which it does when the mon still had its species name (Scatterbug → Spewpa). A change that keeps the species name (a form change) is only logged |

Species names are sent as the sheet's `Sprites` tab spells them (full names where the ROM shortens them, Nidoran-F/-M, Flabebe, form names for Oricorio, Lycanroc and Urshifu); see docs/DESIGN.md "Event schema". Events carry `run` (your trainer id), `playTime` and an `id`, `<run>:<session>.<n>`, unique across script reloads and mGBA restarts; the web app skips ids it has already applied. Kills in doubles use the leftmost live mon and set `ambiguous` when both of yours were alive (the attacker isn't read yet). A jump in play time (loading a savestate or a save) drops the current battle without emitting anything.

Mons already in the party and boxes when the script starts, or after loading a savestate or save, are treated as known and not sent: the sheet may already have them (hand-entered rows have no id), and `sync` will reconcile them. A mon is sent at most once per timeline, and the sheet ignores a catch for an id it already has. Catching a species you already have is sent as a new mon (and logged); evolution lines are not checked.

**Sending a `sync`.** Type `syncToTracker()` in the scripting console (Tools → Scripting, the console's input line) after loading a savestate or an older save, or when the sheet has drifted from the game. It sends the snapshot (every mon in the party and boxes, the defeated trainers, the badge count) and the sheet reconciles its log against it (below); the console says what was sent, or why it wasn't. It sends nothing in a battle (a trainer's defeated flag is only set when the fight ends), before a save is loaded, or while a mon can't be read (the game is rewriting it): in each case try again. Eggs aren't in the snapshot. It is never sent automatically, not even after a play-time jump: you decide when the sheet is reconciled.

Not detected yet: trades (a new party mon with another OT id is only logged).

## Relay

`relay/relay.mjs` (Node 22+, no packages) forwards the tracker's events to the web app in `WEB_APP_URL` with `TOKEN`, both from `.env`. Run it in a terminal while you play:

```sh
npm run relay                                 # or: node relay/relay.mjs
node relay/relay.mjs --env .env.dev           # another sheet's URL and token (the dev copy)
node relay/relay.mjs --help
```

It listens on `127.0.0.1:38765`, checks the URL and token on start, and every 200 ms posts whatever has arrived as one request, logging what the web app did with each event (`sent 2: kill applied, death applied`). Start it before or after mGBA: the tracker connects within two seconds of the relay starting and reconnects if it restarts. The mGBA console shows `relay: connected on port 38765`.

It is best effort and stores nothing. Events detected while the relay isn't running are not sent. If a request fails (no network, the web app erroring or refusing the token), the relay logs why (for a script error, its message) and retries it 3 times, after about 1, 2 and 4 s (each ±50% at random); if that fails too, it drops those events and logs `GAVE UP`. Requests don't wait for each other, so a retried event can reach the sheet after a later one; if a kill lands before its mon's catch, the sheet ignores it and logs it to `_Issues` (and the relay shows `kill ignored (kill for unknown pid …)`). Fix the sheet by hand if that happens. Ctrl-C at any time; anything still waiting is dropped and the relay says how many.

## Relay tests

```
npm run test:relay
```

They run the relay against a fake web app, no network: one request per tick, the web app down, refusing the token or failing, the 3 retries and their waits, dropping a request, a request being retried not holding up the next, the TCP server (lines split across reads, a line cut off by a disconnect, reconnects), and the Apps Script redirect over real HTTP.

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
