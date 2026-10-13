-- Run & Bun tracker for mGBA 0.10.3. Load with Tools > Scripting > File > Load script.
-- For now events are printed to the scripting console as `EVENT {json}` lines; the relay will take them from here.

local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or TRACKER_DIR or "./"
package.path = dir .. "?.lua;" .. package.path

-- mGBA keeps `require`'s cache between script loads, so a reload would silently reuse old modules.
for _, name in ipairs({ "addresses", "gen3", "json", "battle", "mons" }) do package.loaded[name] = nil end

local G = require("gen3")
local J = require("json")
local Battle = require("battle")
local Mons = require("mons")

local function log(msg) console:log(msg) end

local ok, why = G.verify(emu)
if not ok then
  log("tracker: this does not look like Run & Bun 1.0.7 (" .. why .. "); not starting")
  return
end

local play_time -- seconds, nil until a save is loaded
local JUMP = 3  -- play time normally advances by at most 1 s between frames; more (or any decrease) is a load

local function emit(ev)
  ev.run = G.run_id(emu)
  ev.playTime = play_time
  log("EVENT " .. J.encode(ev))
end

local battle = Battle.new(emu, emit, function(msg) log("battle: " .. msg) end)
local mons = Mons.new(emu, emit, function(msg) log("mons: " .. msg) end)

local function on_frame()
  local pt = G.play_time(emu)
  if pt == nil then return end
  if play_time and (pt < play_time or pt > play_time + JUMP) then
    log(string.format("play time jumped %d -> %d (savestate or save loaded)", play_time, pt))
    battle:reset()
    mons:reset()
  end
  play_time = pt
  battle:step()
  mons:step()
end

if TRACKER_CB then callbacks:remove(TRACKER_CB) end
TRACKER_CB = callbacks:add("frame", on_frame)
log("tracker: running (Run & Bun 1.0.7 verified)")
