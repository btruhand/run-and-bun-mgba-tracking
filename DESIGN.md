# Run & Bun Nuzlocke Auto-Tracker — Design

Automatically keep the existing "R&B kill sheet" (Google Sheets, `Rankings` tab) up to date while playing
Pokémon Run & Bun in mGBA. Status: **brainstorm / design only — nothing built yet.**

## Goals

1. **Kill counter per split.** When one of my Pokémon KOs a *trainer's* Pokémon, +1 in the current split's column (Split 1–8, E4 Split) for that Pokémon, and Total KC follows.
2. **Auto-add catches** to the tracker (species, nickname, encounter location).
3. **Auto-mark deaths** (Status → Dead).
4. **Auto-evolve** — when a Pokémon evolves, change its row's species to the new one (keeping its KC history).

Non-goals (for now): level-cap enforcement, dupes/species-clause checking, wild-battle kills, gender/IMG beyond what the sheet already derives, live overlay.

## Splits

| # | Name | Ends when defeated |
|---|------|--------------------|
| 1 | Brawly | Brawly |
| 2 | Roxanne | Roxanne |
| 3 | Wattson | Wattson |
| 4 | Norman | Norman |
| 5 | Flannery | Flannery |
| 6 | Winona | Winona |
| 7 | Tate & Liza | Tate & Liza |
| 8 | Juan | Juan |
| E4 | Victory Road + E4 | (run end) |

The leader fight itself counts toward its own split; the split advances once that leader's defeated-flag is set.
**Current split is derived from game state** (leader-defeated / badge flags in save data), not from the route the fight happens on — a route is only useful as a label for the encounter-location column on catches.
The sheet's existing **Advance Split** checkbox stays as a manual override/fallback.

## Architecture

```
 mGBA (Run & Bun ROM)
   └─ Lua script (reads RAM, detects events)
        │  newline-delimited JSON over localhost TCP
        ▼
 Local relay (small daemon, disk-backed queue, retries)
        │  HTTPS POST + shared secret
        ▼
 Apps Script web app  (doPost, bound to the existing sheet)
        │  dedupes by event id, mutates sheet
        ▼
 Rankings sheet  (+ hidden `_Events` log tab, hidden PID column)
```

Why this shape:

- **mGBA Lua can't do HTTPS** (raw TCP sockets only), so something local has to sit in the middle. The relay is deliberately dumb: forward, queue on disk, retry. It holds no game logic.
- **Apps Script as the sheet writer** (vs. Sheets API + service account): no GCP project/OAuth, it can call the *existing* script functions (Advance Split, sort/rank, counters), and it's where dedupe lives. Trade-off: web-app deployment + a shared-secret token in Script Properties.
- **Lua emits events, not sheet edits.** Lua stays small and testable; all sheet knowledge (rows, columns, formulas) is in one place.
- **Idempotency via event IDs.** Each event has a unique id (`<run-id>:<seq>`). Apps Script records processed ids in `_Events` and ignores repeats, so relay retries, relay restarts, and replays are safe. `_Events` doubles as an audit log and enables an "undo last event" action.
- **Increments, not overwrites.** The script applies deltas (`KC += 1`), so manual edits to the sheet (the Add KO checkbox, fixes) are never clobbered by a stale local state.

### Language choices (recommended)

- Lua 5.4 (mGBA built-in) for the in-emulator script.
- Python 3, stdlib only (`asyncio` + `urllib`), for the relay. Easy to run on macOS with no install.
- Apps Script (manage with `clasp` so it lives in this repo).

## Identifying a Pokémon

Use **personality value (PID) + OT ID** as the stable key. It survives evolution, nickname changes, and box↔party moves, so it is the join key between game and sheet.
Column `E` is **in use** (a formula: `=IF(T3="","",IFERROR(VLOOKUP(T3,{Gemstones!$B:$B,Gemstones!$A:$A},2,FALSE),""))` keyed off Total KC) — the script never writes it and it already sorts along with its row; and `D:T` is otherwise fully used, so the ID goes in a new hidden column **outside** the current sort range (proposed: `Y`, one of the narrow spacer columns). It must travel with its row when the sheet re-sorts, so the sort range is widened to `D3:Y102` (the legacy `autoSortRange` already sorted through `W`, so `U:W` formulas have been sorted along before). **Must be tested on a copy**: if `U:W` misbehave when sorted, fall back to sorting in script (read `D:T` + `Y` with `getFormulasR1C1`, sort in JS, write back). Never match on row number or species/nickname: rows move on every sort. (Reset Run must also clear the ID column.)

## Event detection (Lua)

Run & Bun is a pokeemerald-expansion–based hack, so Gen 3 structures apply but with **expanded species IDs and likely shifted addresses** — see Spike 0.

Polling on the `frame` callback (every N frames for party scanning; every frame while in battle), emitting on state *changes*.

### Reading Pokémon
- Party (6 × 100-byte structs) and PC boxes (via the storage pointer).
- Substructs are encrypted with `PID ^ OTID` and ordered by `PID % 24`; species/level/HP come from the decrypted data. Nickname uses the Gen 3 charset.
- Save block data (flags, badges, map) is behind a **pointer** (`gSaveBlock1Ptr`), so dereference every read.

### Catch
- Keep a set of known PIDs (seeded from the sheet / snapshot at startup). A PID appearing in party or boxes that isn't known → `catch` event with species, nickname, and location.
- **Location comes straight from the game**: every Pokémon records where it was met (`metLocation`, a map-section id) in its own data. Read that and translate it with the game's own map-section name table (read from the ROM, so no hand-maintained list). The string is written to column `J` as-is, whether or not it's in the dropdown (script writes bypass dropdown validation). Gifts/the starter have the special "fateful encounter" met-location, which gives exactly the `Fateful` entry already in your dropdown. Small alias table in `data/` only if some game names differ from what you want to see.
- Gifts, the starter, static encounters and hatched/received mons all just appear as new PIDs and are added the same way; `source: catch|gift` is recorded for the log only.
- **Trades:** an in-game trade replaces one of your mons with another. Detect it as: a tracked PID disappears and, in the same stable scan, an unknown PID appears in the **same party/box slot** with a different original-trainer ID. Emit `trade {old_pid, new_pid, species, nick, location}`. The sheet **substitutes in place**: same row, species/nickname/location/ID replaced, status stays Alive. The row's KC is kept (assumption — substituting the entry, not starting a new one). A PID that vanishes with *no* replacement is not a trade; it's `missing` (see Death).
- Debounce: require the new PID to be seen on 2+ consecutive scans, and ignore scans while in a transition (battle intro, box UI) to avoid phantom adds from mid-swap memory.

### Evolution
- Same PID, different species ID between scans (outside of battle-intro frames) → `evolve {pid, from, to}`. Sheet updates species in place; KC is retained.

### Death
- Party mon HP reaches 0 → candidate. **Commit when the battle ends and HP is still 0** (or immediately when out of battle), so a mid-battle faint that's later handled isn't misread. Revives are illegal in the ruleset, so no un-death logic; a manual sheet edit can fix mistakes.
- A PID that disappears from party+boxes is **not** treated as dead (could be released/traded); emit `missing` and let the sheet flag it. Require absence over several stable scans so box swaps don't trigger it.

### Kill (the hard one)
- Only when `gBattleTypeFlags` says **trainer battle** (wild kills ignored).
- Each frame in battle, watch each enemy battler's HP in `gBattleMons`. On `>0 → 0` for an opposing battler, attribute the kill to `gBattlerAttacker` **if** it's a player-side battler. That gives the right credit in doubles (Run & Bun has them) since the attacker is still set while the damage script runs.
- Self-KO moves (Explosion) still credit the user.
- **Indirect KOs** (poison, weather, hazards, recoil, Destiny Bond…) **count for the player's mon currently on the field** (decided). Rule: if `gBattlerAttacker` isn't a player battler when the enemy faints, credit the player battler that most recently attacked this turn; if none, the leftmost active player battler (singles: just the active mon). Emit these with `indirect: true` so they're visible in the log and easy to correct.
- Map the attacker battler to its party slot → PID (read party at battle start, since slots reorder on switch; re-resolve from `gBattlerPartyIndexes`).
- Target is **mGBA 0.10.3**. Assume polling only (breakpoint/watchpoint Lua APIs may not exist in 0.10 — verify in Spike 0; use them only if present). `socket`, `emu:read*`/`readRange` and the `frame` callback are available.
- Event includes the **split** computed from game flags at that moment.

### Split / progress
- Count the eight leader-defeated/badge flags in game → `badges` (0–8). Split index = `badges` (0 → Split 1 … 7 → Split 8, 8 → E4 Split). Emit `split {badges}` when it changes.
- **Don't simulate a click on Advance Split.** `AA4` *is* the `Badges` cell (row 4 of the right-hand panel), and the Advance Split checkbox just does `AA4++` in `onEdit`, which script writes never trigger anyway. The web app **sets `AA4 = badges`** directly. Same effect, but idempotent: it can't drift or double-advance on retries, savestates or old saves (an increment would). The kill column is still `K + AA4`, so your idea of "Badges decides the split column" is exactly what the sheet already does; we just feed it from the game. The button stays for manual use.

## Event schema

All events: `{ id, run, playTime, type, ... }` where `id` is `<run>:<seq>` (seq persisted by the relay), `run` is the save's trainer ID + secret ID, and `playTime` is **in-game play time in seconds** (see "Savestates & rewinds").

```json
{"type":"sync","playTime":43424,"mons":[{"pid":"...","species":"Piplup","hp":0,"where":"party|box"}],"defeated":["<trainerId>",...],"badges":2,"complete":true}  // on script start and on any play-time discontinuity
{"type":"catch","pid":"0xA1B2C3D4:0x1234ABCD","species":"Piplup","nick":"","location":"Route 104","source":"catch"}
{"type":"trade","old_pid":"...","pid":"...","species":"Nincada","nick":"","location":"Route 116"}
{"type":"kill","pid":"...","split":2,"enemy":"Roxanne's Nosepass","trainer":"<trainerId>","key":"<trainerId>:<enemySlot>","indirect":false}
{"type":"death","pid":"..."}
{"type":"evolve","pid":"...","from":"Piplup","to":"Prinplup"}
{"type":"split","badges":3}
{"type":"snapshot","party":[...],"boxes":[...]}          // periodic, for reconciliation
```

Species names must match what the `Sprites` tab / IMG column expects; a species-ID→name table (Run & Bun's expanded list) lives in `data/`. Locations are whatever the game reports (see Catch).

## Savestates & old saves

**Problem.** Loading a savestate or an older `.sav` rewinds the *game* but not the *sheet*. A kill counter that only ever does `+1` would keep credit for things that, in the timeline you're now in, never happened (or happen again and double-count).

**Key observation: split what the game remembers from what it doesn't.**

| Fact | Does the game store it? | Where the sheet gets it |
|------|------------------------|-------------------------|
| Which mons exist, their species, nickname, location | Yes | **Read from the game** — always correct after any load |
| Which trainers are defeated, badges/split | Yes (flags) | **Read from the game** |
| Alive / dead | Only partly (a fainted party mon has 0 HP; a boxed mon loses that) | Journal, checked against the game where possible |
| **Who got each kill** | **No** | **Journal only** |

So only *kills* (and deaths of boxed mons) depend on remembered history. Everything else is just re-synced from the game.

**Mechanism: a journal + a "sync" check on every discontinuity.**

1. **Journal.** Every automatic event is appended to a hidden `_Events` tab: id, run, in-game play time (`playTime`), type, pid, payload, `active` flag, and the inverse operation (kill → `-1` on that column; catch → remove row; death → Alive; evolve → previous species; trade → swap back).
2. **Detect a load.** In-game play time (in the save block; ticks every frame in RAM; restored by savestates and `.sav` loads) normally advances ≤ 1 s between frames. If it **jumps in either direction** (or on script start), the Lua script sends `sync` containing a snapshot of the game: `playTime`, every mon (pid, species, HP, party/box), the set of defeated-trainer flags, and the current split. It then re-seeds its own memory from the game without emitting events.
3. **Reconcile (Apps Script).** For the same `run`, each journal event is re-evaluated against the snapshot and its `active` flag set accordingly:
   - `playTime` later than `sync.playTime` → **inactive** (it hasn't happened yet in this timeline) — apply the inverse.
   - `catch` / `trade` / `evolve`: active only if the pid (and species) is in the snapshot.
   - `kill`: active only if that trainer is flagged defeated in the snapshot (or `playTime` ≤ now when the fight is mid-battle).
   - `death`: active unless the pid is in the party with HP > 0.
   - Anything previously inactive that now checks out is **re-applied**, so jumping *forward* to a newer savestate restores what a previous backward jump undid.
   Then sheet species/nickname/location for every tracked pid are overwritten from the snapshot, mons in the game but not on the sheet are added, and the current split is set from the flags.
4. **Inverses are conditional** (decrement only if > 0; revert species only if it still equals the event's `to`), so manual edits are never fought. Skipped inverses are written to `_Issues`.
5. A **different `run`** (new trainer ID) never triggers reconcile; it is flagged until you press Reset Run.

**Worked example.** You're at play time 10:00. Kill A (10:05, Mudkip), kill B (10:20, Mudkip), catch X (10:30). Then you realise you forgot to save and load the save from 10:10:
- Play time jumps 10:30 → 10:10 → `sync`. Kill B and catch X are inactive (inverse applied: −1 on Mudkip, X's row removed). Kill A stays (its trainer is still flagged defeated in this save).
- You replay 10:10 onward and Torchic gets the kill instead. A new kill event is journaled and applied. Mudkip stays at 1, Torchic gets 1.
- If you now load the *newer* savestate from 10:30 again: `sync` → the old kill B's trainer is flagged defeated again and X is in the party again → both re-activate. (See limitation below about Torchic's kill.)

**Limitations (stated plainly).**
- **Same fight, two branches.** Kill credit for one enemy mon (`key = trainerId:enemySlot`) can only belong to one mon. If you play a fight twice with different killers and then jump between the two branches, the *most recently recorded* credit wins, so you could land on the wrong branch's attribution. Flagged in `_Issues`; fixable with the manual Add KO / an "undo last event" command. A cheap improvement if it bites: include the battle's starting RNG state in the key to tell branches apart.
- Manual Add KO clicks are not journaled and are never rolled back.
- A boxed mon's death can't be verified from the game; it relies on `playTime` only.
- If the relay/sheet was offline while you loaded states, the `sync` is queued and processed in order, so the outcome is the same, just late.
- A **manual "Resync" action** (menu item in the sheet) re-sends a `sync`-style snapshot on demand.

## Sheet changes (Apps Script)

### What the existing `Sorter.js` does (read from the repo)

- Single `onEdit(e)` on the `Rankings` tab; rows **3–102** (100 mons). Columns: `D` gender, `F` status, `G` IMG, `H` nickname, `I` species, `J` encounter location, `K:S` the nine split KCs, `T` total KC, `W` Add KO checkbox. `AA2` attempt, `AA4` **Badges = current split as a 0-based offset** (KC column = `K + AA4`), `AA7` Advance Split checkbox (`AA4++`), `AA9` Reset Run checkbox (clears `D, F, H:T`, `AA2++`, `AA4=0`).
- Entering a value in `J` initialises the row (Status = `Alive`, `K:S` = 0, `T` = 0); clearing it blanks the row.
- Add KO (`W`) increments the column for `AA4` and recomputes `T`.
- Every edit re-sorts `D3:T102`: by `T` descending, then by `F` ascending (stable second sort, so Alive above Dead, each ordered by KC).
- `autoSortRange()` is an older variant sorting `D3:W102`; it looks unused.

### Consequences for the design

- **`onEdit` does not fire for script writes.** The web app can't rely on it: it must do the row init, total recompute and sort itself. So refactor `Sorter.js` into shared helpers — `initRow(sheet,row)`, `recomputeTotal(sheet,row)`, `sortRankings(sheet)`, `addKill(sheet,row,splitIdx)` — called by both `onEdit` and the new web app. Keeps the manual and automatic paths identical.
- **Rows move on every sort**, and a sort happens after every event. Look rows up by the PID column (inside `D:T`), re-reading after each sort.
- **Reset Run must also clear the PID column** (and should clear the journal for the old attempt).
- Capacity is 100 rows; `catch` fills the first empty row in 3–102 (error to `_Issues` if full).
- Dead mons stay in the table; `death` just sets `F` = `Dead` and re-sorts. The right-hand counters are formulas the script never touches: Alive `=COUNTIF(F3:F102,"Alive")`, Deaths `=COUNTIF(F3:F102,"Dead")`, KO Total `=SUM(T3:T102)`. Other cells (Attempt, Badges, probably Rank) are hand-entered; Badges could optionally be synced from the game's badge flags (opt-in, not in scope for v1).
- Sort range widens from `D3:T102` to `D3:Y102` for the ID column (see Identifying a Pokémon), in both `onEdit` and the shared `sortRankings` helper.

### New web app (`Code.js`, alongside `Sorter.js`; clasp already targets the repo root)

- `doPost(e)`: verify token (Script Properties) → append to `_Events` → dispatch by `type` → apply → record inverse.
- `sync`: reconcile as in "Savestates & old saves".
- `catch`: first empty row; `J` = location (as reported by the game), run `initRow`, set `I` species, `H` nickname, ID column. Skip if the ID is already present.
- `trade`: find the row by `old_pid`; replace ID, `I`, `H`, `J`; keep status and KC.
- `kill`: row by PID; `addKill(row, split)` using the event's own split (not `AA4`, which a human may be mid-click on); then sets `AA4` to the game's split if it differs.
- `death`: `F` = `Dead`; sort.
- `evolve`: `I` = new species by PID.
- `split`: set `AA4` to the game's split.
- `snapshot`: reconcile only — write mismatches (mon in game not on sheet, sheet mon missing in game) to `_Issues` instead of silently editing.
- `LockService` around every write so concurrent POSTs and manual edits don't interleave a sort.

## Edge cases / risks

- **New run.** Never auto-reset. A new trainer ID is flagged; you press Reset Run.
- **Relay down / offline.** Lua reconnects; relay queues to disk; ids dedupe; play-time ordering keeps rollback correct when delayed events arrive in order.
- **Apps Script quotas/latency.** Event volume is a handful per battle. Each event does a sort (~1 s); the relay can batch.
- **Wrong attribution in odd moves** (Pursuit, Future Sight, Perish Song, etc.). Logged with `indirect` flag for review rather than guessed.
- **Address drift.** Addresses are for Run & Bun **1.0.7**; keep them in one `data/addresses.lua` keyed by ROM hash so other versions fail loudly instead of reading garbage.
- **Manual edits vs. journal.** Inverses are conditional and manual edits win; `_Issues` records any inverse that was skipped.

## Repo layout (proposed)

```
DESIGN.md
appsscript/     Sorter.js, Rankings.js, WebApp.js, appsscript.json (clasp rootDir)
lua/            tracker.lua, gen3.lua (struct decode), addresses.lua
relay/          relay.py, config example
data/           species.json, maps.json, flags
tools/          replay.py (feed a recorded NDJSON event stream to the web app)
```

## Build plan

0. **Spike 0 — RAM map (blocker).** For **mGBA 0.10.3 + Run & Bun 1.0.7**, find: party, enemy party, `gBattleMons`, `gBattlerAttacker`, battle type flags, map group/num, save block pointers, play time, trainer ID, leader-defeated flags, species ID table. Sources: community RAM maps/tracker scripts for the hack, the hack's source if published, or scanning via the mGBA scripting console. Confirm which Lua APIs 0.10.3 really has (`socket`, `io`, any breakpoints).
1. **Read-only Lua**: decode party + play time, print to the scripting console. Validate against the game UI.
2. **Relay + Lua socket**: stream events to a local log; no sheet yet.
3. **Detectors**, one at a time: catch → death → evolve → split → kill → rewind (`sync`). Test against a real save and by loading savestates.
4. **Refactor `Sorter.js` into shared helpers**, then add the web app on a **copy** of the sheet; replay recorded events with `tools/replay.py`, including rewind scenarios.
5. Point at the real sheet, play a split live, fix attribution bugs.

## Testing

Layered so most of it runs with no emulator and no Google account:

1. **Unit tests, no I/O.** Gen 3 struct decoding (Lua) against fixture byte dumps taken from real saves; detectors (catch/trade/evolve/death/kill/split) fed recorded memory snapshots; Apps Script logic (reconcile, row lookup, sort, inverses) written as pure functions over a small sheet adapter, run in Node against an in-memory fake sheet.
2. **Emulator-in-the-loop (semi-automatic).** mGBA launched with the ROM, a fixture savestate and `--script tracker.lua`; the script runs N frames and the test asserts on the emitted NDJSON. Needs the ROM and fixture savestates locally (gitignored; tests skip if `RNB_ROM` is unset). Verify the exact CLI flags for 0.10.3 in Spike 0.
3. **Scenario replay against a dev sheet.** `tools/replay.py` posts recorded or hand-written event streams (including the rewind/forward-jump/trade cases) to the dev web app, then reads sheet state back and compares to expected.
4. **Sheet integration on a copy only.** A *copy* of the spreadsheet with its own bound script, deployed as a web app. A test-only `dump` action (returns `D3:Y102` values + formulas, `AA` panel, `_Events`) and `reset` action (restores a known fixture state) exist only when the script property `ENV=dev`; the endpoints refuse to run otherwise, so tests can never touch the real sheet. This is also where the `U:W`-sorts-with-`Y` question gets answered.

Secrets/config (`.env`, gitignored): dev web-app URL, shared token, `RNB_ROM`. The token also lives in Script Properties.

## Decisions made

- Only **trainer** kills count; wild kills ignored.
- **Indirect KOs** credit the player's mon currently on the field (most recent attacker this turn, else leftmost active).
- Game badge flags drive the split: the web app sets `AA4` (the `Badges` cell) directly rather than clicking Advance Split; the button stays as a manual override.
- A trade keeps the row's KC.
- **Location** is read from the Pokémon's own met-location in game and written as-is (no dropdown matching).
- **Gifts, starter, static encounters** get rows; **trades** substitute in place (KC kept).
- Savestates / old saves are handled by the journal + `sync` reconcile; the game is the source of truth for everything it stores.
- Targets: mGBA 0.10.3, Run & Bun 1.0.7.

## Open items / questions

- (Resolved) `U:W` survive the widened `D3:Y102` sort: verified on the dev copy that every row's formulas still reference their own row. The bar graph's `max` is an absolute `$V$3`, which is fine because the table is sorted by KC.
