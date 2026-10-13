# Tools

| Tool | What it does |
|------|--------------|
| `remote.py` (+ `lua/dev/remote.lua`) | drive a running mGBA from a script (below) |
| `state.py` | read RAM out of a savestate offline (below) |

For Claude Code sessions there is a skill, `.claude/skills/remote-controlling-mgba/`, with the working method and lessons for driving the game, and a subagent, `.claude/agents/mgba-driver.md`, for long play sequences (it keeps the screenshots out of the main conversation and reports back with savestates and traces).

## Remote control for mGBA (`remote.py` + `lua/dev/remote.lua`)

Lets a script (or a Claude session) play the game and watch memory without anyone at the keyboard: press buttons, take screenshots, save and load states, and log memory changes every frame. It is how the catch, evolution and PC behavior in [../docs/MEMORY_MAP.md](../docs/MEMORY_MAP.md) was observed. It is a development tool, not part of the tracker.

### Setup

1. Open the ROM in mGBA 0.10.3 and get to the overworld.
2. Tools → Scripting → File → Load script → `lua/dev/remote.lua`. The console prints `remote: polling …/.remote/cmd.lua`.
3. Leave the game running. If "Pause when inactive" is on in mGBA's settings, turn it off.

mGBA 0.10.3 has no command-line flag to load a script, so step 2 is manual. It is only needed again after mGBA restarts (see "Reloading" below).

### Running commands

```sh
python3 tools/remote.py 'log(emu:currentFrame())'
python3 tools/remote.py 'press("A"); wait(30); shot("now")'   # screenshot lands in .remote/now.png
python3 tools/remote.py -f experiment.lua --timeout 120
```

`remote.py` writes the chunk to `.remote/cmd.lua`, waits for `.remote/out-<id>.txt` and prints it. The last line is `OK`, or `ERROR <message>` with a traceback; the exit code follows. `--timeout` (default 30 s) must cover the whole chunk, including its waits.

### What a chunk can use

| | |
|---|---|
| `wait(n)` | let `n` frames pass |
| `press("A")`, `press("DOWN", hold, gap)`, `press("A+B")` | hold keys for `hold` frames (default 6), then release for `gap` frames (default 12) |
| `keys("DOWN DOWN A")` | several presses in a row |
| `shot("name")` | screenshot to `.remote/name.png` |
| `log(...)` | add a line to the command's output |
| `emu:...` | any mGBA core method (`read32`, `readRange`, `saveStateFile`, `loadStateFile`, …) |
| `watch("name", fn)` / `unwatch("name")` | run `fn(frame, wlog, mem)` every frame, across commands; `wlog(...)` appends to `.remote/watch.log` |
| `A`, `G` | `lua/addresses.lua` and `lua/gen3.lua` |
| `S` | a table that survives between commands |

Example: walk in grass until a wild battle starts.

```lua
local function in_battle() return (emu:read8(A.in_battle) >> 1) & 1 == 1 end
for i = 1, 120 do
  if in_battle() then break end
  press((i % 4 < 2) and "LEFT" or "RIGHT", 16, 4)
end
shot("encounter")
```

### How it works, and its quirks

- The script polls for `.remote/cmd.lua` every 6 frames, deletes it, and runs it as a coroutine so `wait` can span frames.
- mGBA refuses `emu` calls from a coroutine ("Function called from invalid context"). Inside a chunk, `emu` is a proxy: each call yields to the frame callback, which makes the real call and resumes the chunk with the result.
- Watchers run in the frame callback itself, so they must read memory through their `mem` argument, not the `emu` proxy.
- `emu:addKeys` is sticky: keys stay down until cleared. The script adds and clears keys in the `keysRead` callback, so each `press` is a real press and release.
- Keys pressed by the script and by you on the keyboard combine, so don't play while a command runs.

### Reloading

After editing `remote.lua`, it can be reloaded without touching mGBA. A watcher runs on the main thread, so it can `dofile` the script, which removes the old callbacks and registers new ones:

```sh
python3 tools/remote.py 'local done = false
watch("reload", function() if done then return end done = true; dofile("<repo>/lua/dev/remote.lua") end)'
```

Watchers from the old copy are dropped, so reinstall any you need.

### Safety

- Never save in-game during experiments: mGBA overwrites the ROM's `.sav` file. Use `emu:saveStateFile` and keep a copy of the `.sav`.
- `.remote/` is gitignored. Savestates worth keeping go to `fixtures/private/` (also gitignored).

## Reading savestates offline (`state.py`)

```sh
python3 tools/state.py read STATE 0x02023716            # one byte
python3 tools/state.py read STATE 0x02023a98 100        # hex dump
python3 tools/state.py u32 STATE 0x03005da4 0x03005d9c  # little-endian values (also u16)
python3 tools/state.py find STATE e78117972365          # where these bytes occur in EWRAM / IWRAM
python3 tools/state.py dump STATE out.bin               # the decompressed state, for diffing
```

`STATE` is a PNG savestate from mGBA's menu (the state is in its `gbAs` chunk) or a raw one from `emu:saveStateFile`. Checking a value across many saved states is often faster than replaying an action in the game.
