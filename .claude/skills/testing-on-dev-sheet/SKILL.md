---
name: testing-on-dev-sheet
description: Simulate tracker events against the DEV copy of the Google Sheet and check what the web app did — deploy appsscript/ to dev, replay a list of events/syncs/undos with sim.mjs, read back Rankings, _Events and _Issues, and pin the behaviour with a scenario in tests/sheet/run.mjs. Use when changing appsscript/*.js or an event's shape, reproducing a problem seen on the live sheet (a GAVE UP in the relay log, a wrong row, an _Issues entry), or checking what the sheet does with a sequence of catches, kills, evolutions, syncs and undos.
---

# Testing on the dev sheet

The dev sheet is a copy of the real one with its own script (`.clasp.dev.json`) and web app (`WEB_APP_URL` and `TOKEN` in `.env.dev`). Its script has `ENV=dev`, which turns on the test-only `dump`, `reset` and `undo` actions. Setup is in README "Development setup".

## Rules

- **Never test against the live sheet** (`.env`, `.clasp.json`): events sent there are applied to the user's run. The only harmless request to it is `{"events": []}` (what the relay sends on start); ask before sending even that. Deploying to it (`npm run deploy`) is the user's call.
- **One user of the dev sheet at a time.** `sim.mjs`, `npm run test:sheet` and a relay started with `--env .env.dev` all write to it, and the first two reset it. Don't run two at once (a background suite included).
- Run `node` and `npm` through direnv, e.g. `direnv exec . npm run test:sheet`: the repo needs Node 22+ (`.nvmrc`), and a shell that doesn't load direnv gets nvm's default instead. Check `direnv exec . node -v` once.
- Changes to `appsscript/` reach the dev web app only after `npm run deploy:dev` (pushes and redeploys the same URL, about 15 s).

## The loop

1. Edit `appsscript/`, then `npm run deploy:dev`.
2. Try it with `sim.mjs` (below), steps file in the scratchpad.
3. Pin it with a scenario in `tests/sheet/run.mjs` (helpers there: `ev`, `catchEv`, `killEv`, `sync`, `mon`, `send`, `dump`, `undo`, `byId`), and run just that one: `npm run test:sheet -- --only "<part of its name>"`.
4. Before finishing, run the whole suite in the background: `npm run test:sheet` takes several minutes (a few seconds per request). Also `npm run test:relay` if `relay/` changed and `npm run test:lua` if `lua/` changed.

## sim.mjs

```sh
node .claude/skills/testing-on-dev-sheet/sim.mjs steps.json      # resets the dev sheet, plays the steps, prints the result
node .claude/skills/testing-on-dev-sheet/sim.mjs --keep -        # steps on stdin, without resetting first
# --full prints the whole final dump (formulas included); --env FILE for another dev copy
```

It asks for a `dump` first and stops if the web app refuses (anything without `ENV=dev`), so it can't write to a real sheet. `steps.json` is a JSON array; each step is one of:

| step | what it does |
| --- | --- |
| `{"type": "catch", ...}` | one event, as its own request |
| `[{...}, {...}]` | several events in one request, like a relay batch |
| `{"action": "undo"}` | the Undo latest tracking change button |
| `{"action": "dump"}` | print the sheet at this point |
| `{"raw": "null"}` | post this body as is (malformed requests) |

Each event gets `run: "sim"`, `id: "sim:<n>"` and `playTime` 10, 20, 30, … unless it sets them; `"id": null` sends none. Event fields are in README "Lua tracker" and "Web app"; `sync` is `{type: "sync", mons: [{pid, species, nick, hp, where: "party"|"box"}], defeated: [trainer ids], badges, complete}` (DESIGN.md "Event schema"); the tracker doesn't send it yet, so only simulations exercise it. Example, the evolution the live sheet rejected:

```json
[
  {"type": "catch", "pid": "0xA:1", "species": "Sizzlipede", "nick": "", "location": "Route 111"},
  [{"type": "evolve", "pid": "0xA:1", "from": "Sizzlipede", "to": "Centskorch", "nick": "Centskorch"},
   {"type": "kill", "pid": "0xA:1", "split": 1, "trainer": 5, "key": "5:0"}]
]
```

It prints each event's status and reason, then Rankings rows, the panel, every `_Events` row (with its row number, status and issue reference) and every `_Issues` row (with its row number).

## Reproducing a problem from the live sheet

- The relay log names the event type and id but not the payload. Get the payload from the `EVENT {json}` lines in mGBA's scripting console, or read the game itself with the remote (`remote-controlling-mgba` skill), e.g. the party's species names:
  `python3 tools/remote.py 'for i=0,5 do local m=G.read_mon(emu, A.party+i*A.mon_size) if m and m.valid then log(i, m.pid, G.species_name(emu, m.species), m.nick) end end'`
- Send what the tracker sends: species names come from the ROM, which cuts them to 10 characters ("Centskorch", "Corvknight"), not the official spelling.
- If it doesn't reproduce on dev, the code is the same (`npm run deploy` stages exactly `appsscript/` in `.build/clasp/`), so look at what differs on the live sheet: its validation rules, protected ranges, hand edits, its `_Events`. Ask the user to check those or the Apps Script editor's Executions page; no tool here reads the live sheet.

## End to end with the real game

`node relay/relay.mjs --env .env.dev` with `lua/tracker.lua` loaded in mGBA sends real events to the dev sheet. Only one relay can listen on port 38765, so the user's live relay has to be stopped first (ask). Reset the dev sheet first (`echo '[]' | node .claude/skills/testing-on-dev-sheet/sim.mjs -`): the first event after a reset sets the tracked run, and events from any other run are held.

## Reading the results

- Every event gets one `_Events` row. A resend of an applied event is a `duplicate`; a resend of one that wasn't applied is handled again and updates its row (new status, earlier issues kept). Statuses: `applied` (on the sheet; `active` says whether a rewind took it off), `ignored` (unknown mon, full table, bad split), `failed` (threw), `held` (another run), `rejected` (no type, run or id), `reconciled` (a sync). Only `applied` rows are rewound, re-applied or undone. `issue reference` lists the `_Issues` rows about the event, as links.
- An exception inside an event or a sync step is caught, logged as `<type> failed: <message> (File:line)` or `sync could not …`, and fails only that event or step. Anything else in the request (the lock, opening the sheet) answers `{"ok": false, "error": "<message>"}`, which the relay retries, and is logged as `request failed: …`. Google's HTML error page instead of JSON means the error escaped the script entirely; `scriptError` in `relay/relay.mjs` pulls the message out of it.
- The line number in a sheet error points at the `SpreadsheetApp.flush()` after the write, not the write itself: Sheets reports a rejected write at its next call, which is why the web app flushes after each event and each sync step.
- The Species column's dropdown rejects names not on its list, which makes an easy exception on purpose (`"to": "Centskorch"`).
- `tests/sheet/run.mjs` follows the web app's redirects by hand; a failed request reports its HTTP status and redirect chain.
- **Lost answers.** Now and then Google redirects the result URL (`script.googleusercontent.com/macros/echo`) back to `/exec` as a bodiless GET, so the reply is `{"ok":false,"error":"unauthorized"}` (from `doGet`), or the result URL answers a Drive "Page Not Found" (HTTP 404), and the POST may well have run (the result URL is only handed out after the script finishes). A scenario failing in one of these two ways says nothing about the change: rerun it with `--only`. Any other failure is real.
