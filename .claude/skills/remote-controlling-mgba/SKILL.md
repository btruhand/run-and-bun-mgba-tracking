---
name: remote-controlling-mgba
description: Drive the running mGBA (Pokémon Run & Bun) from this repo through lua/dev/remote.lua and tools/remote.py — press buttons, take and view screenshots, save/load savestates, trace memory per frame — and read savestates offline with tools/state.py. Use when a task needs the real game: observing how memory changes during an action (catch, evolution, PC, battle), finding an address, checking the tracker against live play, or making fixture savestates.
---

# Remote-controlling mGBA

Tool reference: `tools/README.md`. Addresses: `docs/MEMORY_MAP.md` (also `lua/addresses.lua`). This file is the working method and the lessons from earlier sessions.

## Before anything

1. **Check the remote is alive:** `python3 tools/remote.py 'log(emu:currentFrame(), G.run_id(emu), G.play_time(emu))'`.
   - "never picked up": `remote.lua` is not loaded or the game is paused. Ask the user to load `lua/dev/remote.lua` (Tools → Scripting → File → Load script) and to turn off "Pause when inactive". You cannot load it yourself: mGBA 0.10.3 has no `--script` flag and UI scripting (`osascript`) has no Accessibility permission.
   - If `remote.lua` was edited since it was loaded, hot-reload it (snippet in `tools/README.md`). Reloading drops watchers.
2. **Save a savestate first** (`emu:saveStateFile(<repo>/.remote/<name>.ss, 31)`) so the session can be repeated or undone, and note which one the user's game should end on.
3. Take a screenshot (`shot("now")`, then Read `.remote/now.png`) to see where the game is.

## Rules

- **Never save in-game.** mGBA overwrites `fixtures/private/*.sav`. Use savestates only.
- **Never make the player's choices.** Learning a move (which move to forget), nicknaming, releasing, evolving vs cancelling when the task doesn't say, choosing items to toss: stop and ask (or report back, if you are a subagent). Decline neutrally (B / "No") when you must get past a prompt and the task allows it, and say you did.
- Leave the game where the user expects it: restore the state you agreed on, `unwatch` your watchers, and clear big tables you stored in `S`.
- Don't type while the user may be playing; keys from the script and the keyboard combine.

## Driving the game

- **One screen step per command, then a screenshot.** Blind sequences go wrong: an `A` sent before a menu is ready is lost, or lands on the next menu (this once picked Fight instead of Run and KO'd the target). Batch only steps you have already seen work.
- Timings (frames, 60/s): a tile of walking `press("DIR", 16, 4)`; a text box `wait(60)` before `A`; battle menu after an action `wait(300)` or more; screen transitions 60-120.
- Text prints progressively; screenshots mid-message show partial text. Wait before reading it.
- Yes/No boxes: the cursor starts on Yes. `B` answers No. A Yes/No box can stay drawn after its question ends; prefer `B` to advance when unsure.
- Bag: reopens on the last pocket used, in and out of battle. Pockets in order: Items, Medicine, …, Berries, Poké Balls, Key Items, Mega Stones (wrapping). Check the pocket name in a screenshot before pressing `A`.
- Battle menu: Fight (top-left), Bag (top-right), Pokémon, Run (bottom-right); the cursor remembers its last position.
- Positions: `sb1 + 0` x, `+2` y (u16), `+4` map group, `+5` map number. Useful to walk somewhere without screenshots for every step.
- Run & Bun specifics: the Repellent is a key item toggle (registered to SELECT in the test save; "The Repellent is deactivated" when switched off). No wild encounters while it is on. The Endless Candy raises one level per use without being consumed.
- Catch odds on a full-HP wild mon are low; several balls may break. Reloading the state and retrying does not repeat the same result.

## Observing memory

- Install a **watcher** that logs changes (not every frame) to `.remote/watch.log`; in it read memory through the `mem` argument, never the `emu` proxy. Write a marker line (`echo "--- step" >> .remote/watch.log`) before each action so the log splits by step.
- **Validate mon reads with the checksum** (u16 at `+28` = sum of the 24 decrypted u16 halves of the substructs). The game decrypts mons in place, so single frames read as garbage.
- Don't trust `gPlayerPartyCount`; scan all six slots. Match mons by personality + OT id, not slot.
- `gMain.callback2` (`0x030022c4`) tells which screen is open (values in the memory map). Log it with every trace.
- Box contents: `readRange(storage + 4, 33600)` where `storage = read32(0x03005da4)`; compare 8-byte keys per slot to find changes cheaply.
- **Finding an unknown variable:** snapshot EWRAM (`emu:readRange(0x02000000, 0x40000)`) in each of 2-3 known situations and keep the bytes whose values match the expected pattern (e.g. 0 → 4 on fleeing). Then rank candidates by how often their address appears as a 32-bit literal in the ROM (real globals appear dozens to hundreds of times). Check values on saved states with `tools/state.py` instead of replaying slow in-game actions.
- Some values are only written at the end of a script (e.g. `gBattleOutcome` after the nickname prompt), so a snapshot at the "obvious" moment can miss them.

## Offline

`tools/state.py` reads any savestate (PNG or `saveStateFile` output): `read`, `u16`/`u32`, `find`, `dump`. Use it to confirm a hypothesis across many states at once. Keep states worth reusing in `fixtures/private/` with descriptive names (`r2-<what>.ss`) and record them in `docs/lua_progress/spike-log.md`.

## Writing up

Record new addresses and behaviors in `docs/MEMORY_MAP.md` (with status live / state / static), the method and evidence in `docs/lua_progress/spike-log.md`, and tick `PROGRESS.md`. Say what was observed versus inferred.
