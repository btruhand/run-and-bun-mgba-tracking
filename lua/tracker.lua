-- Run & Bun tracker for mGBA 0.10.3. Load with Tools > Scripting > File > Load script.
-- Each event is printed to the scripting console as `EVENT {json}` and sent over localhost TCP to relay/relay.mjs,
-- which forwards it to the sheet. Events detected while the relay isn't running are not sent (the console says so).

local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or TRACKER_DIR or "./"
package.path = dir .. "?.lua;" .. package.path

-- mGBA keeps `require`'s cache between script loads, so a reload would silently reuse old modules.
for _, name in ipairs({ "addresses", "gen3", "json", "battle", "mons", "sync", "relay_client" }) do package.loaded[name] = nil end

local G = require("gen3")
local J = require("json")
local Battle = require("battle")
local Mons = require("mons")
local Sync = require("sync")
local RelayClient = require("relay_client")

local function log(msg) console:log(msg) end

local ok, why = G.verify(emu)
if not ok then
  log("tracker: this does not look like Run & Bun 1.0.7 (" .. why .. "); not starting")
  return
end

local play_time -- seconds, nil until a save is loaded
local JUMP = 3  -- play time normally advances by at most 1 s between frames; more (or any decrease) is a load

-- A reload replaces the connection; the old one would otherwise stay open until mGBA restarts.
if TRACKER_RELAY then TRACKER_RELAY:close() end
local relay = RelayClient.new(TRACKER_RELAY_PORT or 38765, function(msg) log("relay: " .. msg) end)
TRACKER_RELAY = relay

-- Event ids are `<run>:<session>.<n>`: the session is the clock when the script was first loaded in this mGBA, and
-- both it and n survive reloading the script, so ids never repeat. The web app ignores ids it has already applied,
-- which makes sending an event twice harmless.
TRACKER_SESSION = TRACKER_SESSION or string.format("%x", os.time())
TRACKER_SEQ = TRACKER_SEQ or 0

local function emit(ev)
  ev.run = G.run_id(emu)
  if ev.playTime == nil then ev.playTime = play_time end
  TRACKER_SEQ = TRACKER_SEQ + 1
  ev.id = string.format("%s:%s.%d", tostring(ev.run), TRACKER_SESSION, TRACKER_SEQ)
  local line = J.encode(ev)
  local sent, why = relay:send(line)
  log("EVENT " .. line .. (sent and "" or "  (not sent: " .. why .. ")"))
  return sent
end

local battle = Battle.new(emu, emit, function(msg) log("battle: " .. msg) end)
local mons = Mons.new(emu, emit, function(msg) log("mons: " .. msg) end)

local function on_frame()
  relay:step()
  local pt = G.play_time(emu)
  if pt == nil then return end
  if play_time and (pt < play_time or pt > play_time + JUMP) then
    log(string.format("play time jumped %d -> %d (savestate or save loaded)", play_time, pt))
    battle:reset()
    mons:reset(Mons.LOAD_SETTLE)
  end
  play_time = pt
  battle:step()
  mons:step()
end

-- Call from the scripting console (`syncToTracker()`) after loading a savestate or an older save, or whenever the sheet
-- has drifted from the game: sends what the game has now (every mon, defeated trainers, badges) and the sheet
-- reconciles its event log against it. Returns true if it was sent.
function syncToTracker()
  local snapshot, why = Sync.snapshot(emu)
  if not snapshot then
    log("sync: not sent (" .. why .. ")")
    return false
  end
  snapshot.playTime = G.play_time(emu) -- now, not as of the last frame
  local sent = emit(snapshot)
  if sent then
    log(string.format("sync: sent %d mons, %d defeated trainers, %d badges", #snapshot.mons, #snapshot.defeated, snapshot.badges))
  end
  return sent
end

if TRACKER_CB then callbacks:remove(TRACKER_CB) end
TRACKER_CB = callbacks:add("frame", on_frame)
log("Running (Run & Bun 1.0.7 verified); help is under \"Auto-tracker help text\" in the list on the left")

-- The help goes in a text buffer (the list on the left of the scripting window, shown in the top pane), a fixed grid
-- of columns, so the lines are wrapped here. Each line is printed on its own row: a "\n" inside print() leaves the
-- cursor where the following text wraps at the wrong column. A reload reuses the buffer, or each load would add another.
local HELP = {
  "Auto-tracker help",
  "",
  "Catches, kills, deaths, evolutions and badges reach the sheet on their own.",
  "",
  "Manual commands:",
  "",
  "syncToTracker()",
  "  Type it in the input line below to send the sheet everything the game has",
  "  now (every mon, defeated trainers, badges) so it matches the game. Can be used",
  "  to align the sheet if it has drifted somehow, or after loading a savestate or",
  "  an older save. Ignored if the save isn't the run the sheet is tracking.",
  "",
  "How to use (setup and playing):",
  "  https://github.com/btruhand/run-and-bun-mgba-tracking#how-to-use",
}
if not TRACKER_HELP then TRACKER_HELP = console:createBuffer("Auto-tracker help text") end
TRACKER_HELP:clear()
TRACKER_HELP:setSize(80, #HELP)
for row, line in ipairs(HELP) do
  TRACKER_HELP:moveCursor(0, row - 1)
  TRACKER_HELP:print(line)
end
