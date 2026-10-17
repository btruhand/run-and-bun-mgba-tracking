# Run & Bun Nuzlocke Auto-Tracker — Design

Automatically keep the existing "R&B kill sheet" (Google Sheets, `Rankings` tab) up to date while playing
Pokémon Run & Bun 1.0.7 in mGBA 0.10.3. This file is the design and the reasons behind it. What is built and
checked is in [PROGRESS.md](PROGRESS.md); addresses and observed game behavior are in
[docs/MEMORY_MAP.md](docs/MEMORY_MAP.md).

Status in one line: the Lua tracker (kills, deaths, splits, catches, evolutions), the relay and the web app are built
and work end to end on the dev copy; trades and `sync` are not.

## Goals

1. **Kill counter per split.** When one of my Pokémon KOs a _trainer's_ Pokémon, +1 in the current split's column (Split 1–8, E4 Split) for that Pokémon, and Total KC follows.
2. **Auto-add catches** to the tracker (species, nickname, encounter location), including the starter.
3. **Auto-mark deaths** (Status → Dead).
4. **Auto-evolve**: when a Pokémon evolves, change its row's species to the new one, keeping its KC.
5. **Trades** replace the row's mon in place and keep its KC.
6. **Savestates and old saves** don't corrupt the sheet.

Non-goals (for now): level-cap enforcement, dupes/species-clause checking, wild-battle kills, gender/IMG beyond what the sheet already derives, live overlay.

## Splits

| #   | Name              | Ends when defeated |
| --- | ----------------- | ------------------ |
| 1   | Brawly            | Brawly             |
| 2   | Roxanne           | Roxanne            |
| 3   | Wattson           | Wattson            |
| 4   | Norman            | Norman             |
| 5   | Flannery          | Flannery           |
| 6   | Winona            | Winona             |
| 7   | Tate & Liza       | Tate & Liza        |
| 8   | Juan              | Juan               |
| E4  | Victory Road + E4 | (run end)          |

**A badge increase advances the split.** The sheet's `Badges` cell (`AA4`) picks the KC column (`K + Badges`), and
the Advance Split checkbox just does `Badges++`. The tracker does the same thing from the game: when you earn a
badge, it sends `split {badges}` with the new count, and the web app sets `Badges` to it. The leader fight itself
counts toward its own split, because the kill that finishes the leader is sent before the badge increase.

- **How the tracker sees the increase.** It counts the gym leaders whose trainer-defeated flag is set (0–8). Each
  leader hands over the badge right after the fight, so this count is the badge count; the flag is set on the frame
  the battle ends, before the badge cutscene. The badge flags themselves are not located in Run & Bun (the vanilla
  flag numbering doesn't match), and are not needed; they would only be a cross-check.
- Because it's a count, the order the leaders are beaten in doesn't matter.
- **Set, not clicked.** The web app writes the count instead of simulating Advance Split: script writes don't
  trigger `onEdit`, and an increment can drift or double-advance on retries, savestates and old saves. Setting the
  value gives the same result however often it's applied. Kill events also carry their own split, so a kill lands
  in the right column even if someone is clicking the sheet at that moment.
- The Advance Split button stays for manual use.
- The split is never derived from the route a fight happens on.

## Architecture

```
 mGBA (Run & Bun ROM)
   └─ Lua script (reads RAM, detects events, stamps ids)      built
        │  newline-delimited JSON over localhost TCP (port 38765)
        ▼
 Local relay (relay/relay.mjs: in-memory queue, retries)      built
        │  HTTPS POST + shared secret
        ▼
 Apps Script web app  (doPost, bound to the sheet)            built, on the dev copy
        │  dedupes by event id, mutates sheet
        ▼
 Rankings sheet  (+ hidden `_Events` / `_Issues` tabs, hidden ID column Y)
```

Why this shape:

- **mGBA Lua can't do HTTPS** (raw TCP sockets only), so something local has to sit in the middle. The relay is deliberately dumb: forward, retry briefly, drop. It holds no game logic.
- **Best effort, nothing stored.** An event that can't be delivered (relay not running, or its request failing 4 times in a row) is dropped and logged rather than kept. Delivery failures are rare and a dropped event can be fixed by hand (or by `sync`, once built); in exchange there is nothing to clean up, and no old event can arrive after a Reset Run and be applied to the new run. (A file-based version with a disk queue was built first and replaced for this reason.)
- **Apps Script as the sheet writer** (vs. Sheets API + service account): no GCP project/OAuth, it shares the row logic with the existing buttons, and it's where dedupe lives. Trade-off: web-app deployment + a shared-secret token in Script Properties.
- **Lua emits events, not sheet edits.** Lua stays small and testable; all sheet knowledge (rows, columns, formulas) is in one place.
- **Idempotency via event ids.** Each event has a unique id, stamped by the tracker when it is detected (see "Event schema"). The web app records processed ids in `_Events` and ignores repeats of applied ones, so a retry after a request that did reach the sheet applies nothing twice. A repeat of an event that wasn't applied (failed, ignored, held) is handled again.
- **Increments, not overwrites, for kills.** The web app applies deltas (`KC += 1`), so manual edits (the Add KO checkbox, fixes) are never clobbered.

Languages: Lua 5.4 (mGBA built-in); Node, no packages, for the relay (like the scripts and sheet tests); Apps Script managed with `clasp` in this repo.

## Identifying a Pokémon

**Personality value + OT id** (`"0xA1B2C3D4:0x1234ABCD"`) is the key. Both are stored unencrypted at the start of the struct, so they read correctly even on frames where the rest is being rewritten. The key survives evolution, nickname changes and box↔party moves, and joins game and sheet.

It goes in hidden column **`Y`**, outside `D:T` (which is fully used; `E` is a formula keyed off Total KC). The sort range is widened to `D3:Y102` so the id travels with its row; the `U:W` formulas were checked on the dev copy to still reference their own row after a sort. Rows move on every sort, so rows are always looked up by id, never by row number or species/nickname. Reset Run also clears the id column.

## Event detection (Lua)

Run & Bun is built on pokeemerald-expansion: Gen 3 structures, but expanded species ids and shifted addresses (none of the vanilla Emerald addresses apply). Everything is polled from the `frame` callback; mGBA 0.10.3 has no usable breakpoints from Lua.

Facts from real play that shape every detector (details in docs/MEMORY_MAP.md):

- **The game decrypts a mon in place while it works on it**, so for single frames its data is garbage and the substruct checksum fails (level-ups, evolution, party menu, battle start). A mon read is only trusted when its checksum is valid, and a change only when it reads the same on two scans.
- **Party slots move** (a deposit compacts the party), **`gPlayerPartyCount` goes stale** (in the PC, and for a frame in battle), and **a mon can be in neither party nor box** for a while (withdraw, Move Pokémon). Mons are tracked by key, never by slot or count, and a disappearance means nothing on its own.
- **`gBattleMons` is rewritten in pieces on a switch-in**, briefly showing the new mon with the old mon's HP.

### Reading Pokémon

- Party (6 × 100-byte structs), enemy party, and PC boxes (14 × 30 × 80 bytes, via `gPokemonStoragePtr`).
- Substructs are encrypted with `personality ^ OT id` and ordered by `personality % 24`; species and met location come from the decrypted data. Nicknames use the Gen 3 charset; names (species, trainers, map sections) are read from the ROM's own tables, so there is no hand-maintained list.
- Save block data (flags, play time, trainer id) is behind pointers, dereferenced on every read.

### Catch

- **Wild or static catch:** when a battle ends with `gBattleOutcome = 7` (caught), the enemy mon's key is looked up in the party and boxes and read from where it was stored, so the nickname is the final one. The game stores it after the nickname prompt, before the battle ends; the lookup retries for ~10 s in case it isn't there yet or is mid-rewrite.
- **Starter (and any new own-OT mon outside battle):** a party scan every 30 frames, out of battle only. A new mon must read the same with a valid checksum on two scans. The starter is given by script before the first battle.
- **Location** is the mon's own met location, translated with the ROM's map-section table and written as-is (script writes bypass the dropdown validation). Met location 255 reads as "Fateful Encounter".
- **Known mons:** everything in the party and boxes when tracking starts, or after a savestate/save load, is recorded as known without sending anything; `sync` reconciles those with the sheet. A mon is sent at most once per timeline, and the sheet ignores a catch for an id it already has. Catching a species you already have is a new mon and a new row (logged). Evolution lines are not checked.
- Eggs are not sent until they hatch.

### Trade (not built)

In Run & Bun, gift mons come from NPC trades, and a traded mon always lands in the party. Plan: a tracked key disappears from the party and, in the same stable scan, a new key with **another OT id** appears in the same slot → `trade {old_pid, pid, species, nick, location}`. The sheet substitutes in place: same row, id/species/nickname/location replaced, status and KC kept. Today a new party mon with another OT id is only logged. To check on a real trade: the met location (vanilla uses 254, which the map table doesn't cover; proposed label "In-game Trade") and what the party slot does during the trade screen.

### Evolution

- Same key, different species between party scans, read the same with a valid checksum on two scans (scans don't run in battle) → `evolve {pid, from, to, nick?}`. Only the party is watched; mons don't evolve in boxes.
- The game renames a mon that still has its species name (Scatterbug → Spewpa) on the same frame as the species changes; that new name is sent as `nick`. A mon with its own nickname keeps it.
- A change that keeps the species name (a form change) is logged, not sent.
- Covers the Endless Candy and evolution items (both seen live). A level-up evolution right after a battle is rare in Run & Bun runs and not tested live; the same scan would see it once the battle ends.

### Death

- One of your mons fainting in any battle (wild or trainer) is committed as `death` when the battle ends, once per mon.
- Run & Bun has no overworld fainting, so nothing outside battle is watched.
- Revives are illegal in the ruleset, so there is no un-death logic; a manual sheet edit fixes mistakes.
- A key that disappears from party and boxes is **not** a death (it may be in transit, released or traded). A `missing` event was dropped: `sync` finds mons that are gone.

### Kill

- Only when `gBattleTypeFlags` bit 3 says **trainer battle** (wild kills ignored). `gTrainerBattleOpponent_A` is stale after a battle, so it's only read when that bit is set.
- Every frame in battle, each enemy battler's HP in `gBattleMons` is watched. A `> 0 → 0` drop counts only if species, level, max HP, personality and OT id are the same as on the previous frame (this rejects the switch-in glitch). Each enemy party slot is credited once (`key = <trainer>:<enemy slot>`).
- **Singles:** credited to your mon on the field. That also gives the decided rule for indirect KOs (poison, weather, hazards, recoil, Destiny Bond): they count for the mon currently on the field.
- **Doubles:** `gBattlerAttacker` is not located yet, so the kill goes to your leftmost live mon and the event carries `ambiguous: true` when both of yours were alive. Once the attacker is found, doubles credit becomes exact and an `indirect` flag can mark KOs the attacker didn't cause.
- The event carries the split at that moment (leaders defeated + 1), the trainer id and the enemy's name.

### Split

- After each battle, count the defeated gym leaders (see Splits). If the count went up, send `split {badges}`.
- The leader ids (265–272) come from the ROM's trainer table and were confirmed against a real leader fight.

## Event schema

All events: `{ id, run, playTime, type, ... }`. `id` is `<run>:<session>.<n>` (stamped by the tracker: `session` is the
clock, in hex, when the script was first loaded in this mGBA, and `n` counts up; both survive reloading the script), `run` is the save's trainer id + secret id, and `playTime` is **in-game play time in seconds** (see "Savestates & old saves").

```json
{"type":"catch","pid":"0xA1B2C3D4:0x1234ABCD","species":"Starly","nick":"Starly","location":"Route 102"}
{"type":"kill","pid":"...","split":2,"enemy":"Roxanne's Nosepass","trainer":"<trainerId>","key":"<trainerId>:<enemySlot>","ambiguous":true}   // ambiguous only in doubles
{"type":"death","pid":"..."}
{"type":"evolve","pid":"...","from":"Scatterbug","to":"Spewpa","nick":"Spewpa"}   // nick only if the game renamed it
{"type":"split","badges":3}
{"type":"trade","old_pid":"...","pid":"...","species":"Nincada","nick":"","location":"In-game Trade"}   // not sent yet
{"type":"sync","playTime":43424,"mons":[{"pid":"...","species":"Piplup","nick":"","hp":0,"where":"party|box"}],"defeated":["<trainerId>",...],"badges":2,"complete":true}   // sent by `syncToTracker()`; `hp` only for party mons
```

Species names come from the ROM's species table and are sent as the sheet spells them, since the Species dropdown only accepts the names in `Sprites!D` (and the sprite lookup uses them too). `G.species_name` in `gen3.lua` restores the names the ROM shortens to 10 characters (Centskorch → Centiskorch, and nine more), uses the sheet's Nidoran-F, Nidoran-M and Flabebe, and names the Oricorio, Lycanroc and Urshifu forms by species id, because the ROM names each form the same. Nine species have no `Sprites` row (Venonat, Ditto, Cleffa, Magearna, Marshadow, Poipole, Naganadel, Blacephalon, Zeraora); a catch or evolve of those fails until the sheet lists them.

## Savestates & old saves

**Problem.** Loading a savestate or an older `.sav` rewinds the _game_ but not the _sheet_. A kill counter that only ever does `+1` would keep credit for things that, in the timeline you're now in, never happened (or happen again and double-count).

**What the game remembers and what it doesn't:**

| Fact                                                | Does the game store it?                                            | Where the sheet gets it                               |
| --------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------- |
| Which mons exist, their species, nickname, location | Yes                                                                | **Read from the game**, always correct after any load |
| Which trainers are defeated, badges/split           | Yes (flags)                                                        | **Read from the game**                                |
| Alive / dead                                        | Only partly (a fainted party mon has 0 HP; a boxed mon loses that) | Journal, checked against the game where possible      |
| **Who got each kill**                               | **No**                                                             | **Journal only**                                      |

So only kills (and deaths of boxed mons) depend on remembered history. Everything else is re-synced from the game.

**Mechanism: a journal + a `sync` on every discontinuity.**

1. **Journal (built).** Every event received is appended to a hidden `_Events` tab (a resend updates the event's row instead): id, run, play time, type, pid, payload (a sync's lists only counted), `active` flag, its inverse (kill → `-1` on that column; catch → remove row; death → Alive; evolve → previous species and nickname; trade → swap back; split → previous Badges), `status` (`applied`, `ignored`, `failed`, `held`, `rejected`, `reconciled`) and `issue reference` (links to the `_Issues` rows about it). Only `applied` entries take part in reconcile and undo.
2. **Snapshot (built in Lua, sent by hand).** `syncToTracker()`, called from mGBA's scripting console, sends `sync`: play time, every mon (key, species, nickname, location, HP for party mons, party/box), the defeated trainers (`lua/sync.lua`, `G.defeated_trainers`) and the badge count. It is all or nothing, because the sheet takes a mon missing from the snapshot as gone and undoes its catch: a mon that can't be read right now (mid-rewrite) cancels it, and so does a battle in progress (the defeated flag is set when the fight ends, so the sheet would take the fight's kills back). Eggs are left out (they aren't sent until they hatch). It is manual by choice: an automatic send on every load would be disruptive. In-game play time normally advances ≤ 1 s between frames, and a jump in either direction (or script start) means a load; the Lua side only resets its battle and mon trackers on one, and a test pins that it sends nothing.
3. **Reconcile (built in the web app).** For the same `run`, each journal event is re-evaluated against the snapshot:
   - `playTime` later than `sync.playTime` → **inactive** (hasn't happened yet in this timeline); the inverse is applied.
   - `catch` / `trade` / `evolve`: active only if the mon is in the snapshot.
   - `kill`: active only if that trainer is flagged defeated in the snapshot.
   - `death`: active unless the mon is in the party with HP > 0.
   - Anything previously inactive that now checks out is **re-applied**, so jumping _forward_ to a newer savestate restores what a backward jump undid.
     Then species/nickname for every tracked mon are overwritten from the snapshot, mons in the game but not on the sheet are added, and `Badges` is set from the snapshot.
4. **Inverses are conditional** (revert species only if it still equals the event's `to`, and so on), so manual edits are never fought. Skipped inverses are written to `_Issues`.
5. A **different `run`** (new trainer id) is held, never reconciled, until you press Reset Run.

**Worked example.** You're at play time 10:00. Kill A (10:05, Mudkip), kill B (10:20, Mudkip), catch X (10:30). Then you load the save from 10:10:

- Play time jumps 10:30 → 10:10 → `sync`. Kill B and catch X are inactive (−1 on Mudkip, X's row removed). Kill A stays (its trainer is still flagged defeated in this save).
- You replay 10:10 onward and Torchic gets the kill instead. A new kill event is journaled and applied. Mudkip stays at 1, Torchic gets 1.
- If you now load the _newer_ savestate from 10:30 again: `sync` → kill B's trainer is flagged defeated again and X is in the party again → both re-activate (see the first limitation about Torchic's kill).

**Limitations.**

- **Same fight, two branches.** Credit for one enemy mon (`key`) can only belong to one mon. If you play a fight twice with different killers and then jump between the two branches, the most recently recorded credit wins. Flagged in `_Issues`; fixable by hand. If it bites, the battle's starting RNG state could go into the key to tell branches apart.
- Manual Add KO clicks are not journaled and are never rolled back.
- A boxed mon's death can't be verified from the game; it relies on play time only.
- If the relay or sheet is offline when you load a state, that `sync` is lost (see "Relay"); the next one corrects the sheet.

## Relay (`relay/relay.mjs`)

Node 22+ (`.nvmrc` pins the version), no packages, one process, run from a terminal next to mGBA. It keeps nothing on disk.

1. **Connection.** The relay listens on `127.0.0.1:38765`. The tracker (`lua/relay_client.lua`) tries to connect when
   it loads and every two seconds while disconnected; on localhost a refused connect returns at once, so the game
   doesn't stall. Each event is sent as one JSON line. An event detected while not connected is not sent, and the
   console line says so.
2. **The relay never writes to the connection.** mGBA 0.10.3 sends with a plain `write()` and doesn't ignore SIGPIPE,
   so writing twice to a connection the relay has closed would kill the emulator. Because the relay never writes, the
   socket becoming readable can only mean the relay closed it; the tracker checks every frame and before each send,
   and closes its side first. A short write also closes the connection; the relay ignores a line cut off by a close.
3. **Send.** Lines are queued in memory. Every 200 ms, whatever is queued (usually one event) is taken off the queue
   and sent as one POST (`{token, events}`); Apps Script answers with a redirect to the result, which is followed
   with a GET. The per-event result (applied, duplicate, held, ignored) is logged.
4. **Failures.** Unreachable, an HTTP error, a refused token or an error in the script: the request is retried
   3 times, waiting about 1, 2 and 4 s after each failure (each ±50% at random, so requests that failed together don't
   retry in step). If the third retry fails too, its events are dropped and logged
   (`GAVE UP`). Anything not yet sent when the relay stops is dropped too.
5. **No ordering between requests.** Each request is independent: one being retried doesn't hold up the next, so the
   sheet is never blocked behind a failing request. The cost is that a retried event can land after a later one. The
   case that matters is a `kill`, `death` or `evolve` reaching the sheet before its mon's `catch`: the sheet answers
   `ignored` (unknown pid), the relay logs it, `_Issues` records it, and the row is fixed by hand. Catches and a mon's
   first event are normally minutes apart, so this needs a retry at the wrong moment. `sync` (once built) is the
   other order-sensitive event; it will need the same care.

On start it posts an empty batch to check the URL and token. `--env` picks another `.env` (another sheet), `--port`
another port (the tracker reads `TRACKER_RELAY_PORT`).

## Sheet (Apps Script)

### The existing sheet

- Rows **3–102** (100 mons). Columns: `D` gender, `E` formula keyed off Total KC, `F` status, `G` IMG, `H` nickname, `I` species, `J` encounter location, `K:S` the nine split KCs, `T` total KC, `U:W` formulas and the Add KO checkbox. `AA2` attempt, `AA4` **Badges** (the 0-based split, KC column = `K + AA4`), `AA7` Advance Split (`AA4++`), `AA9` Reset Run, `AA11` Undo latest tracking change.
- Entering a location in `J` initialises the row (Alive, KC 0); clearing it blanks the row. Every edit re-sorts by Total KC descending, then Alive above Dead.
- Alive, Deaths and KO Total are formulas the script never touches.

### What changed (built, on the dev copy)

- **`onEdit` does not fire for script writes**, so the row logic moved from `Sorter.js` into shared helpers in `Rankings.js` (`initRow`, `blankRow`, `recomputeTotal`, `addKc`, `sortRankings`, …), used by both the buttons and the web app.
- Sort range `D3:Y102` (id column `Y`). Reset Run also clears the id column and the event log.
- **`WebApp.js`**: `doPost` checks the token (Script Properties), takes `LockService`, skips ids already in `_Events`, holds events from another run, applies each event and journals it (with its inverse when applied), then sorts once. Errors are caught per event and per sync step (the sheet is flushed after each, since it reports a rejected write only at its next call), written to `_Issues` and referenced from the event's `_Events` row; one failing event doesn't stop the rest of the request. An error outside them answers `{ok: false}` so the relay retries. `onEdit` logs its errors to `_Issues` too. `@OnlyCurrentDoc`. Dev-only `dump` / `reset` / `undo` actions refuse to run unless `ENV=dev`.
- Event handling: `catch` fills the first empty row (skipped if the id is already there; `_Issues` if full); `kill` adds 1 to the event's own split column; `death` sets Dead; `evolve` sets the species (and nickname when sent); `trade` swaps id/species/nickname/location in place; `split` sets `Badges`; `sync` reconciles.
- **Undo latest tracking change** (`AA11`): applies the inverse of the newest active `_Events` entry that changed the sheet and deletes that entry, rather than marking it inactive, because `sync` re-activates inactive entries that still check out. Same lock as `doPost`. Conditional inverses still apply, so manual edits win.

## Edge cases / risks

- **New run.** Started by hand: press Reset Run, which clears `Rankings`, `_Events`, `_Issues` and the tracked run; the first event after it sets the new run. The Lua side doesn't detect new runs; it just sends the current trainer id as `run`. Events from another run before the reset are held (logged to `_Issues`, not applied), so press Reset Run before picking the starter; a later `sync` adds any mon that was missed.
- **Relay down / offline.** Events are dropped (logged in the mGBA console or the relay's terminal) if the relay isn't running, or if their request fails 4 times in a row (about 7 s when the network is down; up to 4 minutes if every attempt runs into the 60 s timeout). Fix the row by hand; `sync`, once built, will correct catches, species, deaths and badges on the next load, but not kill credit.
- **Reset Run while events are in flight.** An event is delivered or dropped within seconds unless the web app hangs, so pressing Reset Run before starting the new game is enough.
- **Apps Script quotas/latency.** A handful of events per battle; each request takes a few seconds, and the web app's lock runs overlapping requests one at a time; events that arrive within the same 200 ms share a request.
- **Odd moves** (Pursuit, Future Sight, Perish Song) in doubles may be credited to the wrong mon until the attacker is read; `ambiguous` marks the doubles cases.
- **Address drift.** Addresses are for Run & Bun **1.0.7** and live in `lua/addresses.lua`. The tracker checks the ROM's name tables at start and refuses to run on anything else.
- **Manual edits vs. journal.** Inverses are conditional and manual edits win; `_Issues` records any skipped inverse.
- **Nuzlocke mistakes and play testing** (recatching a mon, duplicate species): handled without errors, never blocked.

## Repo layout

```
DESIGN.md, PROGRESS.md, README.md
appsscript/     Sorter.js, Rankings.js, WebApp.js, appsscript.json
lua/            tracker.lua (mGBA entry point), battle.lua, mons.lua, gen3.lua, addresses.lua, json.lua
lua/dev/        remote.lua (drive mGBA from a script; development only)
lua/spike/      read-only probes used to find addresses
tools/          remote.py, state.py (offline savestate reads)
tests/lua/      tracker tests on fake memory
tests/sheet/    scenario tests against the dev web app
scripts/        setup-clasp, gen-token, deploy, deploy-dev
docs/           MEMORY_MAP.md, lua_progress/
relay/          relay.mjs
```

## Testing

1. **Lua tests, no emulator** (`npm run test:lua`). The detectors run on a fake memory that writes real encrypted structs with checksums at the real addresses, and models the GBA bus's rotated misaligned reads. Several scenarios replay frame sequences logged from real play. Key rules are broken on purpose to confirm a test fails.
2. **Offline runs on real savestates.** `tools/state.py` reads RAM out of mGBA savestates; a harness runs `tracker.lua` against pairs of real states (e.g. before and after an evolution).
3. **Driving the real game.** `lua/dev/remote.lua` + `tools/remote.py` press buttons, take screenshots, save/load states and log memory every frame from a script. mGBA 0.10.3 has no `--script` flag, so the remote is loaded by hand once per mGBA session. Not an automated test yet.
4. **Sheet scenarios on the dev copy** (`npm run test:sheet`). They post event streams (including rewinds, forward jumps, trades and killer re-attribution) to the dev web app, then read the sheet back with the dev-only `dump`. The endpoints refuse `dump` / `reset` / `undo` unless `ENV=dev`, so tests can never touch the real sheet.
5. **Relay tests, no network** (`npm run test:relay`): a fake web app (including the Apps Script redirect) that can be down, refuse the token or fail; one request per tick, the 3 retries and their 1, 2, 4 s waits, dropping a request, a request being retried not holding up the next, and the TCP server (lines split across reads, a line cut off by a disconnect, reconnects, never writing back). The Lua side (`relay_client.lua`) is tested against a fake of mGBA's socket API in `npm run test:lua`.

Secrets/config (gitignored): `.env.dev` has the dev web-app URL, shared token and deployment id; `.env` (the relay's default) the real sheet's URL and token. The token also lives in Script Properties.

## Decisions made

- Only **trainer** kills count; wild kills ignored.
- **Indirect KOs** credit your mon on the field.
- **A badge increase advances the split.** The tracker reads it as the number of defeated gym leaders, and the web app sets `Badges` to it rather than clicking Advance Split; the button stays for manual use.
- **Catches** come from the battle outcome (caught) or, outside battle, a new own-OT mon in the party (the starter). Gift mons in Run & Bun come from NPC trades, so they are trades, not catches.
- A **trade** substitutes the row in place and keeps its KC.
- **Duplicates:** never add a second row for the same mon (key). Another mon of a species you already have gets its own row; evolution lines aren't checked.
- **Location** is the mon's own met location, written as-is; 255 is "Fateful Encounter".
- **Evolutions** change species in place and keep KC; the nickname follows only when the game renamed the mon.
- Savestates / old saves are handled by the journal + `sync` reconcile; the game is the source of truth for everything it stores.
- Targets: mGBA 0.10.3, Run & Bun 1.0.7.
